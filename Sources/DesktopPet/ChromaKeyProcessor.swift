import Foundation
import CoreGraphics
import ImageIO

enum ChromaKeyError: LocalizedError {
    case ffmpegMissing
    case processFailed(String)
    case noFrames
    case invalidVideo
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "未找到 ffmpeg。请先安装: brew install ffmpeg"
        case .processFailed(let msg):
            return "抠绿幕失败: \(msg)"
        case .noFrames:
            return "未生成任何透明帧"
        case .invalidVideo:
            return "无法读取视频/图片"
        case .copyFailed(let msg):
            return "无法复制视频: \(msg)"
        }
    }
}

final class ChromaKeyProcessor: @unchecked Sendable {
    static let shared = ChromaKeyProcessor()

    /// Working decode width before subject crop/normalize.
    private let workWidth = 480
    /// Final subject max side so all clips look similar on the desktop.
    private let targetSubjectSize = 320

    /// Process a **local** file path (already copied into Application Support).
    func importAndKey(
        localSourceURL: URL,
        displayName: String?,
        clipID: String,
        settings: ChromaKeySettings = .default
    ) throws -> PetClip {
        guard let ffmpeg = FFmpegLocator.resolve() else {
            throw ChromaKeyError.ffmpegMissing
        }

        let framesDir = AppPaths.framesDirectory(id: clipID)
        if let existing = try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil) {
            for url in existing { try? FileManager.default.removeItem(at: url) }
        }

        let name = displayName ?? localSourceURL.deletingPathExtension().lastPathComponent
        let info = try probe(ffmpeg: ffmpeg, url: localSourceURL)

        let rawDir = framesDir.deletingLastPathComponent().appendingPathComponent("raw_\(clipID)", isDirectory: true)
        try? FileManager.default.removeItem(at: rawDir)
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rawDir) }

        let decodeFilter = settings.decodeFilterGraph(workWidth: workWidth)
        let rawPattern = rawDir.appendingPathComponent("%05d.png").path
        try run(ffmpeg: ffmpeg, arguments: [
            "-y",
            "-i", localSourceURL.path,
            "-vf", decodeFilter,
            "-an",
            "-start_number", "1",
            rawPattern
        ])

        let rawFiles = try FileManager.default.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !rawFiles.isEmpty else { throw ChromaKeyError.noFrames }

        // Pass 1: edge-connected key + collect union subject bounds.
        var union = EdgeConnectedKeyer.Bounds.empty
        var keyedURLs: [URL] = []
        keyedURLs.reserveCapacity(rawFiles.count)
        for raw in rawFiles {
            let keyed = rawDir.appendingPathComponent("k_\(raw.lastPathComponent)")
            let bounds = try EdgeConnectedKeyer.keyPNG(at: raw, outputURL: keyed, settings: settings)
            if !bounds.isEmpty {
                union.union(bounds)
            }
            keyedURLs.append(keyed)
        }
        guard !union.isEmpty else { throw ChromaKeyError.noFrames }

        // Pad a little so edges aren't clipped during motion.
        let sampleW = imagePixelSize(at: keyedURLs[0])?.0 ?? workWidth
        let sampleH = imagePixelSize(at: keyedURLs[0])?.1 ?? workWidth
        let pad = max(4, Int(Double(max(union.width, union.height)) * 0.04))
        let crop = union.padded(by: pad, width: sampleW, height: sampleH)

        // Pass 2: crop to subject + normalize size across clips.
        var outSize = (width: targetSubjectSize, height: targetSubjectSize)
        for (idx, keyed) in keyedURLs.enumerated() {
            let out = framesDir.appendingPathComponent(String(format: "%05d.png", idx + 1))
            outSize = try EdgeConnectedKeyer.cropAndNormalizePNG(
                at: keyed,
                outputURL: out,
                crop: crop,
                targetMaxSide: targetSubjectSize
            )
        }

        let frameCount = keyedURLs.count
        let firstURL = AppPaths.frameURL(clipID: clipID, index: 1)
        let lastURL = AppPaths.frameURL(clipID: clipID, index: frameCount)

        guard FileManager.default.fileExists(atPath: firstURL.path),
              FileManager.default.fileExists(atPath: lastURL.path) else {
            throw ChromaKeyError.noFrames
        }

        let firstFP = try FrameFingerprint.make(from: firstURL)
        let lastFP = try FrameFingerprint.make(from: lastURL)

        return PetClip(
            id: clipID,
            name: name,
            sourcePath: localSourceURL.path,
            frameCount: frameCount,
            fps: info.fps > 0 ? info.fps : 24,
            displayWidth: outSize.width,
            displayHeight: outSize.height,
            firstFingerprint: firstFP,
            lastFingerprint: lastFP,
            nextClipIDs: [],
            createdAt: Date()
        )
    }

    /// Fast preview: key a few sample frames with the given settings.
    func renderPreviewFrames(
        localSourceURL: URL,
        settings: ChromaKeySettings,
        outputDirectory: URL,
        duration: TimeInterval
    ) throws -> [URL] {
        guard let ffmpeg = FFmpegLocator.resolve() else {
            throw ChromaKeyError.ffmpegMissing
        }

        try? FileManager.default.removeItem(at: outputDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let decodeFilter = settings.decodeFilterGraph(workWidth: workWidth)
        let safeDuration = max(duration, 0.2)
        let samples: [(name: String, time: Double)] = [
            ("preview_front.png", min(0.15, safeDuration * 0.08)),
            ("preview_mid.png", safeDuration * 0.50),
            ("preview_back.png", max(0, safeDuration * 0.92))
        ]

        var outputs: [URL] = []
        for sample in samples {
            let raw = outputDirectory.appendingPathComponent("raw_\(sample.name)")
            let out = outputDirectory.appendingPathComponent(sample.name)
            try run(ffmpeg: ffmpeg, arguments: [
                "-y",
                "-ss", String(format: "%.3f", sample.time),
                "-i", localSourceURL.path,
                "-vf", decodeFilter,
                "-frames:v", "1",
                "-update", "1",
                raw.path
            ])
            guard FileManager.default.fileExists(atPath: raw.path) else { continue }
            let bounds = try EdgeConnectedKeyer.keyPNG(at: raw, outputURL: raw, settings: settings)
            if bounds.isEmpty {
                try? FileManager.default.removeItem(at: raw)
                continue
            }
            let size = imagePixelSize(at: raw) ?? (workWidth, workWidth)
            let pad = max(4, Int(Double(max(bounds.width, bounds.height)) * 0.04))
            let crop = bounds.padded(by: pad, width: size.0, height: size.1)
            _ = try EdgeConnectedKeyer.cropAndNormalizePNG(
                at: raw,
                outputURL: out,
                crop: crop,
                targetMaxSide: targetSubjectSize
            )
            try? FileManager.default.removeItem(at: raw)
            if FileManager.default.fileExists(atPath: out.path) {
                outputs.append(out)
            }
        }
        guard !outputs.isEmpty else { throw ChromaKeyError.noFrames }
        return outputs
    }

    func probeDuration(url: URL) throws -> TimeInterval {
        guard let ffmpeg = FFmpegLocator.resolve() else {
            throw ChromaKeyError.ffmpegMissing
        }
        return try probe(ffmpeg: ffmpeg, url: url).duration
    }

    private func imagePixelSize(at url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }

    private struct ProbeInfo {
        var fps: Double
        var width: Int
        var height: Int
        var duration: TimeInterval
    }

    private func probe(ffmpeg: String, url: URL) throws -> ProbeInfo {
        let probePath = ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        let bin = FileManager.default.isExecutableFile(atPath: probePath) ? probePath : ffmpeg

        if bin.hasSuffix("ffprobe") {
            let args = [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate:format=duration",
                "-of", "json",
                url.path
            ]
            let result = try runCapturing(executable: bin, arguments: args, allowFailure: false)
            if let data = result.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let streams = json["streams"] as? [[String: Any]]
                let stream = streams?.first
                let w = stream?["width"] as? Int ?? workWidth
                let h = stream?["height"] as? Int ?? workWidth
                let rate = (stream?["avg_frame_rate"] as? String)
                    ?? (stream?["r_frame_rate"] as? String)
                    ?? "24/1"
                var duration = 0.0
                if let format = json["format"] as? [String: Any] {
                    if let d = format["duration"] as? String {
                        duration = Double(d) ?? 0
                    } else if let d = format["duration"] as? Double {
                        duration = d
                    }
                }
                return ProbeInfo(fps: parseRate(rate), width: w, height: h, duration: duration)
            }
        }

        let result = try runCapturing(executable: ffmpeg, arguments: ["-i", url.path], allowFailure: true)
        let fps = parseFpsFromBanner(result.stderr) ?? 24
        let duration = parseDurationFromBanner(result.stderr) ?? 0
        return ProbeInfo(fps: fps, width: workWidth, height: workWidth, duration: duration)
    }

    private func parseRate(_ rate: String) -> Double {
        let parts = rate.split(separator: "/")
        guard parts.count == 2,
              let n = Double(parts[0]),
              let d = Double(parts[1]),
              d != 0 else {
            return Double(rate) ?? 24
        }
        return n / d
    }

    private func parseFpsFromBanner(_ text: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*fps"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }

    private func parseDurationFromBanner(_ text: String) -> Double? {
        let pattern = #"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let hR = Range(match.range(at: 1), in: text),
              let mR = Range(match.range(at: 2), in: text),
              let sR = Range(match.range(at: 3), in: text),
              let h = Double(text[hR]),
              let m = Double(text[mR]),
              let s = Double(text[sR]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private func run(ffmpeg: String, arguments: [String]) throws {
        let result = try runCapturing(executable: ffmpeg, arguments: arguments, allowFailure: false)
        if result.exitCode != 0 {
            let msg = result.stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
            throw ChromaKeyError.processFailed(msg.isEmpty ? "exit \(result.exitCode)" : String(msg))
        }
    }

    private struct Captured {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private func runCapturing(executable: String, arguments: [String], allowFailure: Bool) throws -> Captured {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw ChromaKeyError.processFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !allowFailure && process.terminationStatus != 0 {
            throw ChromaKeyError.processFailed(stderr.isEmpty ? stdout : stderr)
        }
        return Captured(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// Thread-safe fingerprint via ImageIO / CoreGraphics (no AppKit).
enum FrameFingerprint {
    static let size = 8

    static func make(from imageURL: URL) throws -> [Float] {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ChromaKeyError.invalidVideo
        }
        return make(from: image)
    }

    static func make(from image: CGImage) -> [Float] {
        let side = size
        let bytesPerRow = side * 4
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return normalize([Float](repeating: 0, count: side * side * 3))
        }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var values: [Float] = []
        values.reserveCapacity(side * side * 3)
        for i in 0..<(side * side) {
            let o = i * 4
            let a = Float(data[o + 3]) / 255.0
            let r = Float(data[o]) / 255.0 * a
            let g = Float(data[o + 1]) / 255.0 * a
            let b = Float(data[o + 2]) / 255.0 * a
            values.append(r)
            values.append(g)
            values.append(b)
        }
        return normalize(values)
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(Double(na) * Double(nb))
        guard denom > 1e-9 else { return 0 }
        return max(0, min(1, Double(dot) / denom))
    }

    private static func normalize(_ values: [Float]) -> [Float] {
        let mean = values.reduce(0, +) / Float(max(values.count, 1))
        var centered = values.map { $0 - mean }
        let norm = sqrt(centered.reduce(0) { $0 + $1 * $1 })
        if norm > 1e-6 {
            centered = centered.map { $0 / norm }
        }
        return centered
    }
}

enum TransitionMatcher {
    /// Rebuild graph edges from fingerprints. Returns total link count written.
    @discardableResult
    static func rebuildAutoLinks(in state: inout LibraryState) -> Int {
        let clips = state.clips.filter { !$0.isCursorInteractionMaterial }
        guard clips.count >= 2 else {
            for i in state.clips.indices {
                state.clips[i].nextClipIDs = []
            }
            return 0
        }
        let threshold = state.autoLinkThreshold
        var total = 0

        for i in state.clips.indices where !state.clips[i].isCursorInteractionMaterial {
            let from = state.clips[i]
            var scored: [(id: String, score: Double)] = []
            for other in clips where other.id != from.id {
                let score = FrameFingerprint.similarity(from.lastFingerprint, other.firstFingerprint)
                if score >= threshold {
                    scored.append((other.id, score))
                }
            }
            scored.sort { $0.score > $1.score }
            state.clips[i].nextClipIDs = scored.map(\.id)
            total += scored.count
        }
        for i in state.clips.indices where state.clips[i].isCursorInteractionMaterial {
            state.clips[i].nextClipIDs = []
        }
        return total
    }

    static func score(from: PetClip, to: PetClip) -> Double {
        FrameFingerprint.similarity(from.lastFingerprint, to.firstFingerprint)
    }
}
