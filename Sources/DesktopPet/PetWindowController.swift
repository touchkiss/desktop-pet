import AppKit

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

    private var dragOffset: NSPoint?

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
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
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
            self?.onTeleportDragCancel?()
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

    func setPetHiddenForTeleport(_ hidden: Bool) {
        contentView.isHidden = hidden
    }

    func movePetForTeleport(to origin: CGPoint) {
        guard let window else { return }
        window.setFrameOrigin(origin)
        UserDefaults.standard.set(origin.x, forKey: "petOriginX")
        UserDefaults.standard.set(origin.y, forKey: "petOriginY")
    }

    func restorePetPresentation() {
        setTeleportEffectPadding(0)
        contentView.isHidden = false
        contentView.alphaValue = 1
        contentView.layer?.opacity = 1
        contentView.layer?.transform = CATransform3DIdentity
        contentView.layer?.mask = nil
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
            contentView.image = cache.image
            return
        }

        let url = AppPaths.frameURL(clipID: id, index: index)
        guard let image = NSImage(contentsOf: url) else {
            contentView.image = nil
            return
        }
        frameCache = (id, index, image)
        contentView.image = image

        let scale = max(0.35, min(store.state.petScale, 3.0))
        let w = CGFloat(clip.displayWidth) * scale
        let h = CGFloat(clip.displayHeight) * scale
        petDisplaySize = NSSize(width: w, height: h)
        contentView.petContentSize = petDisplaySize

        var frame = window.frame
        let top = frame.maxY - effectPadding
        let left = frame.origin.x + effectPadding
        frame.size = NSSize(width: w + effectPadding * 2, height: h + effectPadding * 2)
        frame.origin.x = left - effectPadding
        frame.origin.y = top - h - effectPadding
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
