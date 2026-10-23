import AppKit
import AVFoundation
import ImageIO
import CoreImage

/// Published movies are immutable. Original sequence backups are never used for normal playback.
enum ClipMedia {
    static func movieURL(id: String) -> URL {
        AppPaths.frameURL(clipID: id, index: 1).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("animation.mov")
    }

    static func hasMovie(id: String) -> Bool {
        FileManager.default.fileExists(atPath: movieURL(id: id).path)
    }

    /// For scrubbing, export and effects only. Continuous playback uses AVPlayerLayer.
    static func image(id: String, index: Int, fps: Double) -> NSImage? {
        if let image = NSImage(contentsOf: AppPaths.frameURL(clipID: id, index: index)) {
            return image
        }
        guard fps.isFinite, fps > 0, index > 0, hasMovie(id: id) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL(id: id)))
        generator.appliesPreferredTrackTransform = true
        generator.apertureMode = .cleanAperture
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: Double(index - 1) / fps, preferredTimescale: 1_000_000_000)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// One native video decoder per visible surface; no per-frame conversion to NSImage.
@MainActor
final class AlphaVideoPlayback {
    let layer = AVPlayerLayer()
    private let player = AVPlayer()
    private let movieURLForID: (String) -> URL
    private var id: String?
    private var previousFrame = 0
    private var fps = 24.0
    private var isSeeking = false
    private var seekTargetTime: TimeInterval = 0
    private var generation = 0
    private var shouldPlay = false
    private var output: AVPlayerItemVideoOutput?
    private var lastSnapshot: NSImage?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    func playbackTime(for id: String) -> TimeInterval? {
        guard self.id == id, player.currentItem?.status != .failed else { return nil }
        if isSeeking { return seekTargetTime }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    init(movieURLForID: @escaping (String) -> URL = { ClipMedia.movieURL(id: $0) }) {
        self.movieURLForID = movieURLForID
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        layer.player = player
        layer.videoGravity = .resize
        layer.backgroundColor = NSColor.clear.cgColor
    }

    var isActive: Bool { id != nil }

    @discardableResult
    func display(id: String, frame: Int, frameCount: Int, fps: Double,
                 playing: Bool = true, in host: NSView, rect: CGRect, preserveAspect: Bool = false, aspectRatio: CGFloat? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: movieURLForID(id).path), fps.isFinite, fps > 0 else {
            stop()
            return false
        }
        host.wantsLayer = true
        if layer.superlayer !== host.layer { host.layer?.addSublayer(layer) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if preserveAspect, let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 {
            let width = min(rect.width, rect.height * aspectRatio)
            let height = width / aspectRatio
            layer.videoGravity = .resize
            layer.frame = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                                 width: width, height: height)
        } else {
            layer.videoGravity = preserveAspect ? .resizeAspect : .resize
            layer.frame = rect
        }
        CATransaction.commit()
        shouldPlay = playing && frame < frameCount
        let changed = self.id != id
        if changed {
            generation += 1
            isSeeking = false
            self.id = id
            self.fps = fps
            let item = AVPlayerItem(url: movieURLForID(id))
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            self.output = output
            lastSnapshot = nil
            player.replaceCurrentItem(with: item)
        }
        if player.currentItem?.status == .failed {
            stop()
            return false
        }
        let time = CMTime(seconds: Double(max(0, frame - 1)) / fps, preferredTimescale: 1_000_000_000)
        // Frame wrap, clip switch or explicit scrub/hold must seek. Ordinary ticks do not.
        if changed || frame < previousFrame || (!playing && frame != previousFrame)
            || (frame == frameCount && previousFrame != frameCount) {
            generation += 1
            let revision = generation
            isSeeking = true
            seekTargetTime = time.seconds
            player.pause()
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, revision == self.generation else { return }
                    self.isSeeking = false
                    if finished && self.shouldPlay { self.player.play() }
                }
            }
        } else if !shouldPlay {
            player.pause()
        } else if !isSeeking && player.rate == 0 {
            player.play()
        }
        previousFrame = frame
        return true
    }

    func snapshot() -> NSImage? {
        guard let id else { return nil }
        if let buffer = output?.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
            let image = CIImage(cvPixelBuffer: buffer)
            if let cg = imageContext.createCGImage(image, from: image.extent) {
                lastSnapshot = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        if let lastSnapshot { return lastSnapshot }
        let fallback = ClipMedia.image(id: id, index: max(1, previousFrame), fps: fps)
        lastSnapshot = fallback
        return fallback
    }

    func pause() {
        shouldPlay = false
        player.pause()
    }

    func stop() {
        generation += 1
        shouldPlay = false
        isSeeking = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        output = nil
        lastSnapshot = nil
        layer.removeFromSuperlayer()
        id = nil
        previousFrame = 0
    }
}
