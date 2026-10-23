// Run: swiftc -target arm64-apple-macosx13.0 Sources/DesktopPet/AlphaVideoEncoder.swift scripts/test-alpha-video.swift -o /tmp/test-alpha-video && /tmp/test-alpha-video
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct AlphaVideoSmokeTest {
    static func main() {
        DispatchQueue.global(qos: .userInitiated).async {
            do { try run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        dispatchMain()
    }

    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alpha-video-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (width, height, count, fps) in [(64, 48, 5, 29.97), (65, 49, 3, 23.976), (65, 49, 1, 12.5), (65, 48, 2, 30.0), (64, 49, 2, 24.0)] {
            let prefix = "\(width)x\(height)-\(count)"
            var frames: [URL] = []
            for frame in 0..<count {
                let url = directory.appendingPathComponent("\(prefix)-\(frame).png")
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(CGColor(red: 1, green: CGFloat(frame) / CGFloat(count), blue: 0.2, alpha: 0.5))
                context.fill(CGRect(x: 8, y: 8, width: width - 16, height: height - 16))
                let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, context.makeImage()!, nil)
                precondition(CGImageDestinationFinalize(destination))
                frames.append(url)
            }
            let output = directory.appendingPathComponent("\(prefix).mov")
            try AlphaVideoEncoder.encode(frameURLs: frames, fps: fps, outputURL: output)
            let result = try AlphaVideoEncoder.validate(url: output, expectedFrameCount: count, fps: fps)
            precondition(result.width == ((width + 1) & ~1) && result.height == ((height + 1) & ~1) && result.frameCount == count)
            precondition(result.hasTransparentPixels)
            let original = try Data(contentsOf: output)
            try expectFailure("existing output") {
                try AlphaVideoEncoder.encode(frameURLs: frames, fps: fps, outputURL: output)
            }
            let preserved = try Data(contentsOf: output)
            precondition(preserved == original)
            print("PASS \(prefix) fps=\(fps), duration=\(result.duration), alpha=true")
        }
        for (width, height) in [(65, 49), (65, 48), (64, 49), (64, 48)] {
            try testContentGeometry(directory: directory, width: width, height: height)
        }
        let missing = directory.appendingPathComponent("missing.png")
        let output = directory.appendingPathComponent("invalid.mov")
        try expectFailure("empty frames") { try AlphaVideoEncoder.encode(frameURLs: [], fps: 24, outputURL: output) }
        try expectFailure("missing input") { try AlphaVideoEncoder.encode(frameURLs: [missing], fps: 24, outputURL: output) }
        try expectFailure("invalid fps") { try AlphaVideoEncoder.encode(frameURLs: [missing], fps: .nan, outputURL: output) }
        try expectFailure("missing output directory") {
            let source = directory.appendingPathComponent("64x48-5-0.png")
            try AlphaVideoEncoder.encode(frameURLs: [source], fps: 24,
                outputURL: directory.appendingPathComponent("not-created/output.mov"))
        }
        try expectFailure("mixed frame dimensions") {
            try AlphaVideoEncoder.encode(frameURLs: [
                directory.appendingPathComponent("64x48-5-0.png"),
                directory.appendingPathComponent("65x49-3-0.png")
            ], fps: 24, outputURL: output)
        }
        let invalidVideo = directory.appendingPathComponent("corrupt.mov")
        try Data("not a movie".utf8).write(to: invalidVideo)
        try expectFailure("corrupt movie validation") {
            try AlphaVideoEncoder.validate(url: invalidVideo, expectedFrameCount: 1, fps: 24)
        }
        try expectFailure("wrong frame count validation") {
            try AlphaVideoEncoder.validate(url: directory.appendingPathComponent("64x48-5.mov"),
                                           expectedFrameCount: 6, fps: 29.97)
        }
        precondition(!FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".alpha-") }
        precondition(leftovers.isEmpty)
        print("PASS invalid inputs, collision preservation, temporary-file cleanup")
    }

    static func testContentGeometry(directory: URL, width: Int, height: Int) throws {
        let source = directory.appendingPathComponent("edges-\(width)x\(height).png")
        let movie = directory.appendingPathComponent("edges-\(width)x\(height).mov")
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // One-pixel asymmetric alpha rows/columns detect even a one-pixel crop or translation.
        for (rect, alpha) in [
            (CGRect(x: 0, y: 0, width: width, height: 1), 0.25),
            (CGRect(x: 0, y: height - 1, width: width, height: 1), 0.75),
            (CGRect(x: 0, y: 1, width: 1, height: height - 2), 0.5),
            (CGRect(x: width - 1, y: 1, width: 1, height: height - 2), 1.0)
        ] {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            context.fill(rect)
        }
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        try AlphaVideoEncoder.encode(frameURLs: [source, source, source], fps: 24, outputURL: movie)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.apertureMode = .cleanAperture
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let originalBytes = rgbaBytes(image)
        for frame in 0..<3 {
            let decoded = try generator.copyCGImage(at: CMTime(value: Int64(frame), timescale: 24), actualTime: nil)
            precondition(decoded.width == ((width + 1) & ~1) && decoded.height == ((height + 1) & ~1))
            // The app presents coded even dimensions at the clip's original display dimensions.
            let decodedBytes = rgbaBytes(decoded, width: width, height: height)
            for y in 0..<height {
                for x in 0..<width where x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                    let offset = (y * width + x) * 4 + 3
                    precondition(abs(Int(originalBytes[offset]) - Int(decodedBytes[offset])) <= 8,
                                 "Edge moved/cropped at \(width)x\(height) frame \(frame) (\(x),\(y)): \(originalBytes[offset]) -> \(decodedBytes[offset])")
                }
            }
        }
        print("PASS asymmetric one-pixel perimeter \(width)x\(height)")
    }

    static func rgbaBytes(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> [UInt8] {
        let width = width ?? image.width
        let height = height ?? image.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                         count: width * height * 4))
    }

    static func expectFailure(_ name: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { print("PASS rejected \(name): \(error.localizedDescription)"); return }
        throw NSError(domain: "AlphaVideoSmokeTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected rejection: \(name)"])
    }
}
