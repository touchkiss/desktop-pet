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
final class AlphaVideoPlayback: NSObject {
    let layer = AVPlayerLayer()
    private var player: AVPlayer?
    private let powerMonitor: PlaybackPowerMonitor
    private let playerFactory: () -> AVPlayer
    private let uptime: () -> TimeInterval
    private let maximumPlayerAge: TimeInterval
    private var playerCreatedAt: TimeInterval = 0
    private var resumeTime: TimeInterval = 0
    private var currentMovieURL: URL?
    var isSuspended: Bool { powerMonitor.isSuspended }
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
        guard self.id == id, player?.currentItem?.status != .failed else { return nil }
        if isSeeking { return seekTargetTime }
        guard !isSuspended, let player else { return resumeTime }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    init(movieURLForID: @escaping (String) -> URL = { ClipMedia.movieURL(id: $0) },
         powerMonitor: PlaybackPowerMonitor? = nil,
         playerFactory: @escaping () -> AVPlayer = { AVPlayer() },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         maximumPlayerAge: TimeInterval = 30 * 60) {
        self.movieURLForID = movieURLForID
        let powerMonitor = powerMonitor ?? .shared
        self.powerMonitor = powerMonitor
        self.playerFactory = playerFactory
        self.uptime = uptime
        self.maximumPlayerAge = maximumPlayerAge
        super.init()
        layer.videoGravity = .resize
        layer.backgroundColor = NSColor.clear.cgColor
        powerMonitor.changes.addObserver(self, selector: #selector(powerChanged),
                                        name: PlaybackPowerMonitor.didChange, object: powerMonitor)
    }

    isolated deinit {
        powerMonitor.changes.removeObserver(self)
        releasePlayer()
    }

    var isActive: Bool { id != nil }

    @discardableResult
    func display(id: String, frame: Int, frameCount: Int, fps: Double,
                 playing: Bool = true, in host: NSView, rect: CGRect, preserveAspect: Bool = false, aspectRatio: CGFloat? = nil) -> Bool {
        let changed = self.id != id
        let url = changed ? movieURLForID(id) : (currentMovieURL ?? movieURLForID(id))
        guard (!changed && currentMovieURL != nil || FileManager.default.fileExists(atPath: url.path)),
              fps.isFinite, fps > 0 else {
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
        let wrapped = frame < previousFrame
        let time = Double(max(0, frame - 1)) / fps
        let needsSeek = changed || wrapped || (!playing && frame != previousFrame)
            || (frame == frameCount && previousFrame != frameCount)
        self.id = id
        self.fps = fps
        currentMovieURL = url
        if isSuspended {
            if needsSeek { resumeTime = time }
            previousFrame = frame
            return true
        }
        let renew = player == nil || ((changed || wrapped) && uptime() - playerCreatedAt >= maximumPlayerAge)
        if renew { releasePlayer() }
        if changed || player == nil {
            installItem(url: url)
        }
        guard let player else { return false }
        if player.currentItem?.status == .failed {
            stop()
            return false
        }
        if needsSeek || renew {
            seek(to: time)
        } else if !shouldPlay {
            player.pause()
        } else if !isSeeking && player.rate == 0 {
            player.play()
        }
        previousFrame = frame
        return true
    }

    private func removeOutput() {
        if let output { player?.currentItem?.remove(output) }
        output = nil
        lastSnapshot = nil
    }

    private func installItem(url: URL) {
        generation += 1
        isSeeking = false
        removeOutput()
        player?.currentItem?.cancelPendingSeeks()
        if player == nil {
            let player = playerFactory()
            player.isMuted = true
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
            playerCreatedAt = uptime()
            layer.player = player
        }
        player?.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    private func seek(to seconds: TimeInterval) {
        guard let player else { return }
        generation += 1
        let revision = generation
        removeOutput()
        player.currentItem?.cancelPendingSeeks()
        isSeeking = true
        seekTargetTime = seconds
        resumeTime = seconds
        player.pause()
        let time = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, revision == self.generation, !self.isSuspended else { return }
                self.isSeeking = false
                if finished && self.shouldPlay { self.player?.play() }
            }
        }
    }

    private func releasePlayer() {
        generation += 1
        isSeeking = false
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        removeOutput()
        layer.player = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    @objc private func powerChanged() {
        if isSuspended {
            if isSeeking { resumeTime = seekTargetTime }
            else if let seconds = player?.currentTime().seconds, seconds.isFinite {
                resumeTime = max(0, seconds)
            }
            releasePlayer()
        } else if id != nil, let url = currentMovieURL {
            installItem(url: url)
            seek(to: resumeTime)
        }
    }

    func snapshot() -> NSImage? {
        guard let id, !isSuspended, let player else { return nil }
        if output == nil, let item = player.currentItem {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            self.output = output
        }
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
        player?.pause()
    }

    func stop() {
        shouldPlay = false
        releasePlayer()
        layer.removeFromSuperlayer()
        id = nil
        currentMovieURL = nil
        previousFrame = 0
        resumeTime = 0
    }
}
