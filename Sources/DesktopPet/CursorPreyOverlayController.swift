import AppKit
import DesktopPetCore

/// Click-through cursor visual that loops a keyed prey clip while preserving
/// the real cursor as the only input hotspot.
@MainActor
final class CursorPreyOverlayController: NSObject, NSWindowDelegate {
    /// Called once when an already-active overlay can no longer render safely.
    var onFailure: (() -> Void)?

    private(set) var isActive = false

    private let cacheLimit = 24
    private var window: NSWindow?
    private var imageView: NSImageView?
    private let video = AlphaVideoPlayback()
    private var videoFrameCount = 1
    private var driverTimer: Timer?
    private var playback = CursorPreyPlaybackState()
    private var clipID: String?
    private var fps = 0.0
    private var lastDriverTickTime: TimeInterval?
    private var frameCache: [Int: NSImage] = [:]
    private var cacheOrder: [Int] = []
    private var cursorVisibility = CursorVisibilityLeaseState()
    private var previousFrontmostApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var activationTimeoutTimer: Timer?
    private var sessionRevision: UInt = 0

    isolated deinit {
        stop()
    }

    /// Presents a cursor-prey clip. Failures before the first visible frame do
    /// not hide the system cursor and are reported to the caller as `false`.
    @discardableResult
    func start(clip: PetClip, settings: CursorPreySettings) -> Bool {
        stop()

        guard clip.tags.contains(ClipTag.cursorPrey),
              clip.frameCount > 0,
              clip.fps.isFinite,
              clip.fps > 0,
              clip.displayWidth > 0,
              clip.displayHeight > 0,
              let firstImage = loadImage(clipID: clip.id, index: 1),
              firstImage.size.width.isFinite,
              firstImage.size.height.isFinite,
              firstImage.size.width > 0,
              firstImage.size.height > 0 else {
            return false
        }

        let size = overlaySize(for: clip, displaySize: settings.displaySize)
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              let window = makeWindow(size: size),
              let imageView = window.contentView as? NSImageView else {
            return false
        }

        self.window = window
        self.imageView = imageView
        clipID = clip.id
        fps = clip.fps
        videoFrameCount = clip.frameCount
        frameCache[1] = firstImage
        cacheOrder = [1]
        guard playback.start(frameCount: clip.frameCount),
              positionWindowAtCursor(),
              showFirstFrame(in: window, imageView: imageView) else {
            stop()
            return false
        }
        let startTime = ProcessInfo.processInfo.systemUptime
        guard startTime.isFinite, startTime >= 0 else {
            stop()
            return false
        }

        // The first frame is on-screen before the visibility lease starts.
        guard cursorVisibility.start() == .requestForeground else {
            stop()
            return false
        }
        let revision = sessionRevision
        isActive = true
        lastDriverTickTime = startTime

        guard startDriver(for: revision) else {
            failActiveOverlay()
            return false
        }
        guard beginForegroundCursorHide(for: revision) else {
            failActiveOverlay()
            return false
        }
        return true
    }

    /// Stops the overlay and restores the pointer only if this controller hid it.
    func stop() {
        video.stop()
        sessionRevision &+= 1
        driverTimer?.invalidate()
        driverTimer = nil
        lastDriverTickTime = nil
        activationTimeoutTimer?.invalidate()
        activationTimeoutTimer = nil
        removeActivationObserver()

        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        imageView = nil
        frameCache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        clipID = nil
        fps = 0
        playback.stop()
        isActive = false

        let previousApplication = previousFrontmostApplication
        previousFrontmostApplication = nil
        if cursorVisibility.stop() == .showCursor {
            _ = CGDisplayShowCursor(CGMainDisplayID())
        }
        if NSApp.isActive, let previousApplication, !previousApplication.isTerminated {
            _ = previousApplication.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func makeWindow(size: CGSize) -> NSWindow? {
        let window = CursorPreyOverlayWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.delegate = self

        let imageView = NSImageView(frame: CGRect(origin: .zero, size: size))
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView = imageView
        return window
    }

    private func overlaySize(for clip: PetClip, displaySize: Double) -> CGSize {
        let longestSide = CGFloat(CursorInteractionPolicy.clampedPreyDisplaySize(displaySize))
        let aspectRatio = CGFloat(clip.displayWidth) / CGFloat(clip.displayHeight)
        if aspectRatio >= 1 {
            return CGSize(width: longestSide, height: longestSide / aspectRatio)
        }
        return CGSize(width: longestSide * aspectRatio, height: longestSide)
    }

    private func showFirstFrame(in window: NSWindow, imageView: NSImageView) -> Bool {
        guard let image = frameCache[1] else { return false }
        imageView.image = image
        imageView.displayIfNeeded()
        window.orderFrontRegardless()
        window.displayIfNeeded()
        return window.isVisible
    }

    private func startDriver(for revision: UInt) -> Bool {
        let interval = 1.0 / 60.0
        guard interval.isFinite, interval > 0,
              fps.isFinite, fps > 0 else {
            return false
        }

        let driverTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.driverTick(for: revision)
            }
        }
        self.driverTimer = driverTimer
        RunLoop.main.add(driverTimer, forMode: .common)
        return driverTimer.isValid
    }

    private func driverTick(for revision: UInt) {
        guard isActive, revision == sessionRevision else { return }
        guard driverTimer?.isValid == true,
              let window,
              window.isVisible,
              !window.isMiniaturized,
              let imageView,
              window.contentView === imageView,
              imageView.window === window else {
            failActiveOverlay()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now.isFinite,
              let lastDriverTickTime,
              lastDriverTickTime.isFinite,
              now > lastDriverTickTime else {
            failActiveOverlay()
            return
        }
        let elapsed = now - lastDriverTickTime
        guard elapsed.isFinite, elapsed > 0,
              let nextFrame = playback.advance(elapsed: elapsed, fps: fps),
              positionWindowAtCursor() else {
            failActiveOverlay()
            return
        }
        self.lastDriverTickTime = now
        if let clipID, video.display(id: clipID, frame: nextFrame, frameCount: videoFrameCount,
                                    fps: fps, in: imageView, rect: imageView.bounds) {
            imageView.image = nil
        } else if let image = loadFrame(nextFrame) {
            imageView.image = image
        } else {
            failActiveOverlay()
        }
    }

    private func beginForegroundCursorHide(for revision: UInt) -> Bool {
        let currentApplication = NSRunningApplication.current
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != currentApplication.processIdentifier {
            previousFrontmostApplication = frontmost
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completeForegroundCursorHide(for: revision)
            }
        }

        if NSApp.isActive {
            completeForegroundCursorHide(for: revision)
            return cursorVisibility.isActive
        }

        let timeout = Timer(timeInterval: 0.75, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, revision == self.sessionRevision else { return }
                self.failActiveOverlay()
            }
        }
        activationTimeoutTimer = timeout
        RunLoop.main.add(timeout, forMode: .common)
        return currentApplication.activate(options: [.activateIgnoringOtherApps])
    }

    private func completeForegroundCursorHide(for revision: UInt) {
        guard isActive, revision == sessionRevision,
              cursorVisibility.didBecomeActive() == .hideCursor else { return }

        activationTimeoutTimer?.invalidate()
        activationTimeoutTimer = nil
        removeActivationObserver()

        guard CGDisplayHideCursor(CGMainDisplayID()) == .success else {
            failActiveOverlay()
            return
        }
        guard cursorVisibility.didHideCursor() == .restorePreviousApplication else {
            _ = CGDisplayShowCursor(CGMainDisplayID())
            failActiveOverlay()
            return
        }

        let previousApplication = previousFrontmostApplication
        if let previousApplication, !previousApplication.isTerminated {
            if !previousApplication.activate(options: [.activateIgnoringOtherApps]) {
                NSApp.deactivate()
            }
        } else {
            NSApp.deactivate()
        }
    }

    private func removeActivationObserver() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func positionWindowAtCursor() -> Bool {
        guard let window else { return false }
        let cursor = NSEvent.mouseLocation
        guard NSScreen.screens.contains(where: { $0.frame.contains(cursor) }) else {
            return false
        }

        window.setFrameOrigin(CGPoint(
            x: cursor.x - window.frame.width / 2,
            y: cursor.y - window.frame.height / 2
        ))
        return true
    }

    private func loadFrame(_ index: Int) -> NSImage? {
        guard let clipID else {
            return nil
        }
        if let image = frameCache[index] { return image }
        guard let image = loadImage(clipID: clipID, index: index) else { return nil }

        frameCache[index] = image
        cacheOrder.append(index)
        if cacheOrder.count > cacheLimit {
            frameCache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return image
    }

    private func loadImage(clipID: String, index: Int) -> NSImage? {
        guard index > 0 else { return nil }
        guard let image = ClipMedia.image(id: clipID, index: index, fps: fps),
              image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        return image
    }

    private func frameURL(clipID: String, index: Int) -> URL {
        let filename = String(format: "%05d.png", index)
        return AppPaths.clipsRoot
            .appendingPathComponent(clipID, isDirectory: true)
            .appendingPathComponent("frames", isDirectory: true)
            .appendingPathComponent(filename)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }
        failActiveOverlay()
    }

    private func failActiveOverlay() {
        guard isActive else { return }
        let failure = onFailure
        stop()
        failure?()
    }
}

private final class CursorPreyOverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
