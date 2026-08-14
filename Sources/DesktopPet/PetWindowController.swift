import AppKit
import DesktopPetCore

/// Transparent pet surface: drag opaque pixels to move the floating window.
final class PetContentView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    /// Logical pet size inside this view (window may be larger during FX padding).
    var petContentSize: CGSize = .zero {
        didSet { needsDisplay = true }
    }

    var onDragBegan: (() -> Void)?
    /// Quick click without movement — petting.
    var onTapped: (() -> Void)?
    /// Drag released with speed — throw the cat.
    var onFlung: ((CGVector) -> Void)?

    private var dragOffset: NSPoint?
    private var didDrag = false
    private var downTime: TimeInterval = 0
    private var dragSamples: [(time: TimeInterval, origin: NSPoint)] = []

    override var isOpaque: Bool { false }

    /// Rect where the pet image is drawn (centered).
    var imageDrawRect: CGRect {
        let size = petContentSize == .zero ? bounds.size : petContentSize
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let image else { return }
        image.draw(
            in: imageDrawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard image != nil, imageDrawRect.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onDragBegan?()
        guard let window else { return }
        let loc = event.locationInWindow
        dragOffset = NSPoint(x: loc.x, y: loc.y)
        didDrag = false
        downTime = ProcessInfo.processInfo.systemUptime
        dragSamples.removeAll()
        window.makeKeyAndOrderFront(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragOffset else { return }
        let screenPoint = NSEvent.mouseLocation
        let origin = NSPoint(
            x: screenPoint.x - dragOffset.x,
            y: screenPoint.y - dragOffset.y
        )
        window.setFrameOrigin(origin)

        didDrag = true
        dragSamples.append((ProcessInfo.processInfo.systemUptime, origin))
        if dragSamples.count > 6 {
            dragSamples.removeFirst()
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
        let now = ProcessInfo.processInfo.systemUptime
        if !didDrag, now - downTime < 0.4 {
            onTapped?()
        } else if didDrag,
                  let first = dragSamples.first,
                  let last = dragSamples.last,
                  last.time - first.time > 0.01 {
            let dt = CGFloat(last.time - first.time)
            let velocity = CGVector(
                dx: (last.origin.x - first.origin.x) / dt,
                dy: (last.origin.y - first.origin.y) / dt
            )
            if hypot(velocity.dx, velocity.dy) > 350 {
                onFlung?(velocity)
            }
        }
        NotificationCenter.default.post(name: .petPositionDidChange, object: window?.frame.origin)
    }
}

final class PetWindowController: NSWindowController {
    private let contentView = PetContentView()
    private let store: LibraryStore
    private let engine: PlaylistEngine
    private var frameCache: (clipID: String, index: Int, image: NSImage)?
    private var petDisplaySize: CGSize = .zero
    private var effectPadding: CGFloat = 0

    var onTeleportDragCancel: (() -> Void)?
    /// Quick click on the cat — petting.
    var onPetTapped: (() -> Void)?

    private var flingTimer: Timer?
    private var flingVelocity = CGVector.zero
    /// True while thrown physics own the window position.
    private(set) var isFlinging = false

    /// Fired for every rendered frame (even suppressed ones) so an in-flight
    /// teleport effect can feed live frames into its staging layers.
    var onFrameRendered: ((NSImage) -> Void)?

    /// While a teleport effect owns the visuals, the live view stays blank
    /// (the effect shows the frames instead) but frames keep flowing above.
    var suppressLiveImageForEffect = false

    /// While a teleport trip is in flight the CONTROLLER owns the window
    /// geometry: refreshFrame keeps updating images but must not move or
    /// resize the window, killing every tick-ordering race that made the
    /// cat hop after reappearing.
    var freezeFrameForTeleport = false

    var effectHost: PetContentView { contentView }

    init(store: LibraryStore, engine: PlaylistEngine) {
        self.store = store
        self.engine = engine

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.title = "Desktop Pet"
        window.isReleasedWhenClosed = false

        super.init(window: window)

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView

        contentView.onDragBegan = { [weak self] in
            self?.stopFling()
            self?.onTeleportDragCancel?()
        }
        contentView.onTapped = { [weak self] in
            self?.onPetTapped?()
        }
        contentView.onFlung = { [weak self] velocity in
            self?.onTeleportDragCancel?()
            self?.startFling(velocity: velocity)
        }

        restoreOrPositionDefault()
        applyWindowFlags()
        refreshFrame()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(libraryChanged),
            name: .libraryDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(persistPosition(_:)),
            name: .petPositionDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func currentPetFrame() -> CGRect {
        window?.frame ?? .zero
    }

    /// Snapshot of the current pet image (for the tile-swarm journey).
    func petSnapshot() -> CGImage? {
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        return rep.cgImage
    }

    func setPetHiddenForTeleport(_ hidden: Bool) {
        contentView.isHidden = hidden
    }

    func movePetForTeleport(to origin: CGPoint) {
        guard let window else { return }
        window.setFrameOrigin(origin)
        UserDefaults.standard.set(origin.x, forKey: "petOriginX")
        UserDefaults.standard.set(origin.y, forKey: "petOriginY")
    }

    /// One-shot landing placement: the window takes the size of the clip
    /// about to appear, centered on the landing point (clamped on-screen).
    /// Called by the teleport controller while frames are frozen, so the
    /// effect, its canvas and the final live window all share ONE rect.
    func setTeleportLandingFrame(center: CGPoint, size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        if let screen {
            origin = TeleportMath.clampOrigin(origin, petSize: size, visibleFrame: screen.visibleFrame)
        }
        window.setFrame(CGRect(origin: origin, size: size), display: true)
        contentView.needsDisplay = true
        UserDefaults.standard.set(origin.x, forKey: "petOriginX")
        UserDefaults.standard.set(origin.y, forKey: "petOriginY")
    }

    // MARK: - Thrown physics

    private func startFling(velocity: CGVector) {
        stopFling()
        isFlinging = true
        flingVelocity = velocity
        var lastTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let dt = CGFloat(min(0.05, now - lastTime))
                lastTime = now
                self.stepFling(dt: dt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flingTimer = timer
    }

    private func stepFling(dt: CGFloat) {
        guard let window, dt > 0, isFlinging else { return }
        var origin = window.frame.origin
        let size = window.frame.size
        var velocity = flingVelocity

        velocity.dy -= 2600 * dt          // gravity
        velocity.dx *= (1 - 0.9 * dt)     // air drag

        origin.x += velocity.dx * dt
        origin.y += velocity.dy * dt

        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            if origin.x < visible.minX {
                origin.x = visible.minX
                velocity.dx = -velocity.dx * 0.55
            }
            if origin.x + size.width > visible.maxX {
                origin.x = visible.maxX - size.width
                velocity.dx = -velocity.dx * 0.55
            }
            if origin.y + size.height > visible.maxY {
                origin.y = visible.maxY - size.height
                velocity.dy = -velocity.dy * 0.4
            }
            var grounded = false
            if origin.y < visible.minY {
                origin.y = visible.minY
                velocity.dy = -velocity.dy * 0.5
                velocity.dx *= 0.75
                grounded = true
            }
            if grounded, hypot(velocity.dx, velocity.dy) < 40 {
                window.setFrameOrigin(origin)
                stopFling()
                UserDefaults.standard.set(origin.x, forKey: "petOriginX")
                UserDefaults.standard.set(origin.y, forKey: "petOriginY")
                NotificationCenter.default.post(name: .petPositionDidChange, object: origin)
                return
            }
        }
        flingVelocity = velocity
        window.setFrameOrigin(origin)
    }

    func stopFling() {
        flingTimer?.invalidate()
        flingTimer = nil
        isFlinging = false
    }

    func restorePetPresentation() {
        setTeleportEffectPadding(0)
        suppressLiveImageForEffect = false
        freezeFrameForTeleport = false
        contentView.isHidden = false
        contentView.alphaValue = 1
        contentView.layer?.removeAllAnimations()
        contentView.layer?.opacity = 1
        contentView.layer?.transform = CATransform3DIdentity
        contentView.layer?.mask = nil
        refreshFrame()
    }

    /// Grow the transparent window so rings / dust aren't clipped.
    func setTeleportEffectPadding(_ padding: CGFloat) {
        guard let window else { return }
        let padding = max(0, padding)
        guard abs(padding - effectPadding) > 0.5 else { return }
        let old = effectPadding
        effectPadding = padding
        var frame = window.frame
        // Keep visual center stable when padding changes.
        frame.origin.x -= (padding - old)
        frame.origin.y -= (padding - old)
        frame.size.width += (padding - old) * 2
        frame.size.height += (padding - old) * 2
        window.setFrame(frame, display: true)
        contentView.needsDisplay = true
    }

    func applyWindowFlags() {
        guard let window else { return }
        window.level = store.state.alwaysOnTop ? .floating : .normal
        window.ignoresMouseEvents = store.state.clickThrough
    }

    func refreshFrame() {
        guard let window,
              let id = engine.currentClipID,
              let clip = store.clip(id: id) else {
            contentView.image = nil
            return
        }

        let index = engine.currentFrameIndex
        if let cache = frameCache, cache.clipID == id, cache.index == index {
            contentView.image = suppressLiveImageForEffect ? nil : cache.image
            onFrameRendered?(cache.image)
            return
        }

        let url = AppPaths.frameURL(clipID: id, index: index)
        guard let image = NSImage(contentsOf: url) else {
            contentView.image = nil
            return
        }
        frameCache = (id, index, image)
        contentView.image = suppressLiveImageForEffect ? nil : image
        onFrameRendered?(image)

        let scale = max(0.35, min(store.state.petScale, 3.0))
        let w = CGFloat(clip.displayWidth) * scale
        let h = CGFloat(clip.displayHeight) * scale
        petDisplaySize = NSSize(width: w, height: h)
        contentView.petContentSize = petDisplaySize

        // During a teleport trip the controller owns geometry — image and
        // petContentSize keep updating above, but the window must not move.
        guard !freezeFrameForTeleport else { return }

        // Anchor at BOTTOM-CENTER when clip crops differ in size: the feet
        // stay planted and the body grows upward/centered. (Top-left
        // anchoring made the cat visibly hop whenever the next clip's crop
        // height differed — most noticeable right after a teleport.)
        var frame = window.frame
        let bottom = frame.minY
        let centerX = frame.midX
        frame.size = NSSize(width: w + effectPadding * 2, height: h + effectPadding * 2)
        frame.origin.x = centerX - frame.size.width / 2
        frame.origin.y = bottom
        window.setFrame(frame, display: true)
    }

    private func restoreOrPositionDefault() {
        guard let window else { return }
        if let x = UserDefaults.standard.object(forKey: "petOriginX") as? Double,
           let y = UserDefaults.standard.object(forKey: "petOriginY") as? Double {
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        positionBottomRight()
    }

    private func positionBottomRight() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 40,
            y: visible.minY + 40
        )
        window.setFrameOrigin(origin)
    }

    @objc private func persistPosition(_ note: Notification) {
        guard let origin = note.object as? NSPoint else { return }
        UserDefaults.standard.set(origin.x, forKey: "petOriginX")
        UserDefaults.standard.set(origin.y, forKey: "petOriginY")
    }

    @objc private func libraryChanged() {
        applyWindowFlags()
        refreshFrame()
    }
}

extension Notification.Name {
    static let libraryDidChange = Notification.Name("DesktopPet.libraryDidChange")
    static let playbackDidChange = Notification.Name("DesktopPet.playbackDidChange")
    static let petPositionDidChange = Notification.Name("DesktopPet.petPositionDidChange")
}
