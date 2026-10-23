import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Encodes PNG frames without flattening their alpha channel. Call from a background queue.
enum AlphaVideoEncoder {
    static let codecVersion = 2
    enum EncodingError: LocalizedError {
        case invalidInput(String)
        case failed(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .invalidInput(let message), .failed(let message), .timedOut(let message): return message
            }
        }
    }

    struct Validation {
        let width: Int
        let height: Int
        let frameCount: Int
        let duration: Double
        let hasTransparentPixels: Bool
        let sampledAlphaRanges: [Int: AlphaRange]
    }

    struct AlphaRange {
        let minimum: UInt8
        let maximum: UInt8
    }

    private static let timeout: TimeInterval = 60
    private static let timeScale: CMTimeScale = 1_000_000_000

    static func encode(frameURLs: [URL], fps: Double, outputURL: URL) throws {
        guard !Thread.isMainThread else {
            throw EncodingError.invalidInput("透明视频编码必须在后台线程执行。")
        }
        guard !frameURLs.isEmpty, fps.isFinite, fps > 0, fps <= Double(timeScale),
              (Double(frameURLs.count) / fps).isFinite,
              Double(frameURLs.count) / fps < Double(Int64.max) / Double(timeScale) else {
            throw EncodingError.invalidInput("视频帧数和帧率必须有效。")
        }
        guard outputURL.isFileURL else { throw EncodingError.invalidInput("输出必须是本地文件。") }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw EncodingError.invalidInput("输出文件已存在，未覆盖：\(outputURL.lastPathComponent)")
        }
        let first = try loadImage(frameURLs[0])
        let width = first.width
        let height = first.height
        // HEVC truncates odd coded dimensions. Fractional clean apertures also lose
        // a perimeter row in AVFoundation display decoding on tested hardware.
        // Fill the next even dimensions without cropping; callers retain the original
        // clip display dimensions, restoring the original presentation aspect ratio.
        let encodedWidth = (width + 1) & ~1
        let encodedHeight = (height + 1) & ~1
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".alpha-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
        writer.movieTimeScale = timeScale
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: encodedWidth,
            AVVideoHeightKey: encodedHeight
        ])
        input.mediaTimeScale = timeScale
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: encodedWidth,
                kCVPixelBufferHeightKey as String: encodedHeight,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
        guard writer.canAdd(input) else { throw EncodingError.failed("系统不支持透明 HEVC 视频编码。") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EncodingError.failed("无法开始视频编码。") }
        writer.startSession(atSourceTime: .zero)
        var sourceAlphaRanges: [Int: AlphaRange] = [:]
        do {
            for (index, url) in frameURLs.enumerated() {
                try autoreleasepool {
                    let deadline = Date().addingTimeInterval(timeout)
                    while !input.isReadyForMoreMediaData {
                        guard writer.status == .writing else {
                            throw writer.error ?? EncodingError.failed("视频编码器意外停止。")
                        }
                        guard Date() < deadline else { throw EncodingError.timedOut("等待视频编码器超时。") }
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    let image = try loadImage(url)
                    guard image.width == width, image.height == height else {
                        throw EncodingError.invalidInput("所有视频帧必须具有相同尺寸。")
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        throw EncodingError.failed("无法创建视频像素缓冲池。")
                    }
                    var optionalBuffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                          let buffer = optionalBuffer else {
                        throw EncodingError.failed("无法分配视频帧缓冲区。")
                    }
                    try draw(image, into: buffer)
                    if index == 0 || index == frameURLs.count / 2 || index == frameURLs.count - 1 {
                        sourceAlphaRanges[index] = alphaRange(buffer)
                    }
                    let presentationTime = CMTime(seconds: Double(index) / fps, preferredTimescale: timeScale)
                    guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                        throw writer.error ?? EncodingError.failed("写入视频帧失败。")
                    }
                }
            }
            writer.endSession(atSourceTime: CMTime(seconds: Double(frameURLs.count) / fps,
                                                   preferredTimescale: timeScale))
            input.markAsFinished()
            let completion = DispatchSemaphore(value: 0)
            writer.finishWriting { completion.signal() }
            guard completion.wait(timeout: .now() + timeout) == .success else {
                throw EncodingError.timedOut("完成视频编码超时。")
            }
            guard writer.status == .completed else {
                throw writer.error ?? EncodingError.failed("视频编码未正常完成。")
            }
            let result = try validate(url: temporaryURL, expectedFrameCount: frameURLs.count, fps: fps)
            guard result.width == encodedWidth, result.height == encodedHeight else {
                throw EncodingError.failed("编码后画面尺寸发生变化：\(result.width)x\(result.height)，预期 \(width)x\(height)。")
            }
            for (index, sourceRange) in sourceAlphaRanges {
                guard let decodedRange = result.sampledAlphaRanges[index],
                      abs(Int(sourceRange.minimum) - Int(decodedRange.minimum)) <= 8,
                      abs(Int(sourceRange.maximum) - Int(decodedRange.maximum)) <= 8 else {
                    throw EncodingError.failed("编码后首帧、中间帧或尾帧的透明度发生变化。")
                }
            }
            // A same-directory hard link publishes atomically and fails if another writer won the name.
            try FileManager.default.linkItem(at: temporaryURL, to: outputURL)
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    /// Checks the alpha track flag, duration, exact decoded frame count, and first/middle/last frames.
    @discardableResult
    static func validate(url: URL, expectedFrameCount: Int, fps: Double) throws -> Validation {
        guard expectedFrameCount > 0, fps.isFinite, fps > 0 else {
            throw EncodingError.invalidInput("校验视频的帧数或帧率无效。")
        }
        guard !Thread.isMainThread else {
            throw EncodingError.invalidInput("透明视频校验必须在后台线程执行。")
        }
        let asset = AVURLAsset(url: url)
        let metadata = try loadMetadata(asset)
        let track = metadata.track
        let expectedDuration = Double(expectedFrameCount) / fps
        let duration = metadata.duration
        guard duration.isFinite, abs(duration - expectedDuration) <= 0.000_002 else {
            throw EncodingError.failed("视频时长与原始帧率不一致。")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EncodingError.failed("无法校验透明视频。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EncodingError.failed("无法读取透明视频。") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        // cancelReading interrupts a decoder that gets stuck inside copyNextSampleBuffer().
        let watchdog = DispatchWorkItem { reader.cancelReading() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        var count = 0
        var width = 0
        var height = 0
        let aperture = metadata.aperture
        var sampledAlphaRanges: [Int: AlphaRange] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard Date() < deadline else { throw EncodingError.timedOut("解码校验视频超时。") }
            let foundFrame: Bool = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw EncodingError.failed("视频帧无法解码。")
                }
                let currentWidth = CVPixelBufferGetWidth(buffer)
                let currentHeight = CVPixelBufferGetHeight(buffer)
                if count == 0 { width = currentWidth; height = currentHeight }
                guard width == currentWidth, height == currentHeight else {
                    throw EncodingError.failed("视频帧尺寸不一致。")
                }
                let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard abs(timestamp - Double(count) / fps) <= 0.000_002 else {
                    throw EncodingError.failed("视频帧时间戳与原始帧率不一致。")
                }
                if count == 0 || count == expectedFrameCount / 2 || count == expectedFrameCount - 1 {
                    sampledAlphaRanges[count] = alphaRange(buffer)
                }
                count += 1
                guard count <= expectedFrameCount else { throw EncodingError.failed("视频帧数多于预期。") }
                return true
            }
            if !foundFrame { break }
        }
        guard reader.status == .completed, count == expectedFrameCount else {
            throw reader.error ?? EncodingError.failed("视频帧数与预期不一致。")
        }
        return Validation(width: Int(aperture.width), height: Int(aperture.height), frameCount: count, duration: duration,
                          hasTransparentPixels: sampledAlphaRanges.values.contains { $0.minimum < 250 },
                          sampledAlphaRanges: sampledAlphaRanges)
    }

    private struct Metadata {
        let track: AVAssetTrack
        let duration: Double
        let aperture: CGRect
    }

    private final class MetadataResult: @unchecked Sendable {
        let lock = NSLock()
        var value: Result<Metadata, Error>?

        func store(_ value: Result<Metadata, Error>) {
            lock.lock()
            defer { lock.unlock() }
            self.value = value
        }
    }

    private static func loadMetadata(_ asset: AVURLAsset) throws -> Metadata {
        let result = MetadataResult()
        let completion = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let value: Result<Metadata, Error>
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first,
                      try await track.load(.mediaCharacteristics).contains(.containsAlphaChannel) else {
                    throw EncodingError.failed("视频不包含透明通道。")
                }
                let duration = CMTimeGetSeconds(try await asset.load(.duration))
                let descriptions = try await track.load(.formatDescriptions)
                guard let description = descriptions.first else {
                    throw EncodingError.failed("无法读取视频画面尺寸。")
                }
                let aperture = CMVideoFormatDescriptionGetCleanAperture(description, originIsAtTopLeft: true)
                let naturalSize = try await track.load(.naturalSize)
                guard aperture.width > 0, aperture.height > 0,
                      abs(naturalSize.width - aperture.width) < 0.01,
                      abs(naturalSize.height - aperture.height) < 0.01 else {
                    throw EncodingError.failed("视频显示尺寸与有效画面不一致。")
                }
                value = .success(Metadata(track: track, duration: duration, aperture: aperture))
            } catch { value = .failure(error) }
            result.store(value)
            completion.signal()
        }
        guard completion.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            asset.cancelLoading()
            throw EncodingError.timedOut("读取视频元数据超时。")
        }
        result.lock.lock()
        defer { result.lock.unlock() }
        guard let value = result.value else { throw EncodingError.failed("视频元数据未返回。") }
        return try value.get()
    }

    private static func loadImage(_ url: URL) throws -> CGImage {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw EncodingError.invalidInput("无法读取 PNG 帧：\(url.lastPathComponent)")
        }
        return image
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw EncodingError.failed("无法绘制透明视频帧。")
        }
        context.clear(CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer),
                                      height: CVPixelBufferGetHeight(buffer)))
    }

    private static func alphaRange(_ buffer: CVPixelBuffer) -> AlphaRange {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return AlphaRange(minimum: 255, maximum: 255) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var minimum: UInt8 = 255
        var maximum: UInt8 = 0
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                minimum = min(minimum, row[x * 4 + 3])
                maximum = max(maximum, row[x * 4 + 3])
            }
        }
        return AlphaRange(minimum: minimum, maximum: maximum)
    }
}
