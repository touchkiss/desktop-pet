import AppKit
import DesktopPetCore

/// A paused comparison independent of the full-motion preview and desktop playback.
@MainActor
final class ClipCalibrationView: NSStackView {
    var onBatchCalibration: ((PetClip) -> Void)?
    var onUndoBatchCalibration: (() -> Void)?
    private static let referenceKey = "clipCalibration.referenceClipID"
    private let defaults: UserDefaults
    private let canvas = ClipCalibrationCanvas()
    private let sizeEditor = NSStackView()
    private let batchButton = NSButton(title: "首帧批量标定…", target: nil, action: nil)
    private let undoBatchButton = NSButton(title: "撤销批量标定", target: nil, action: nil)
    private let referencePopup = NSPopUpButton()
    private let referenceInfo = NSTextField(labelWithString: "")
    private let frameSlider = NSSlider()
    private let frameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let opacitySlider = NSSlider(value: 0.3, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "30%")
    private let zoomSlider = NSSlider(value: 1, minValue: 0.2, maxValue: 2, target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var clips: [PetClip] = []
    private var current: PetClip?
    private var reference: PetClip?
    private var globalScale = 1.0
    private var frameIndex = 1

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let title = NSTextField(labelWithString: "尺寸标定 · 首帧参照")
        title.font = .boldSystemFont(ofSize: 13)
        addArrangedSubview(title)

        referencePopup.target = self
        referencePopup.action = #selector(referenceChanged)
        referencePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        referencePopup.setAccessibilityLabel("标定参照片段")
        let refresh = NSButton(title: "更新参照", target: self, action: #selector(refreshReference))
        addArrangedSubview(row([NSTextField(labelWithString: "参照"), referencePopup, refresh]))
        referenceInfo.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        referenceInfo.textColor = .secondaryLabelColor
        addArrangedSubview(referenceInfo)
        batchButton.target = self
        batchButton.action = #selector(batchCalibrationRequested)
        undoBatchButton.target = self
        undoBatchButton.action = #selector(undoBatchCalibrationRequested)
        undoBatchButton.isEnabled = false
        addArrangedSubview(row([batchButton, undoBatchButton]))

        let visible = NSButton(checkboxWithTitle: "显示参照", target: self, action: #selector(visibilityChanged(_:)))
        visible.state = .on
        let guides = NSButton(checkboxWithTitle: "辅助线", target: self, action: #selector(guidesChanged(_:)))
        guides.state = .on
        let reset = NSButton(title: "重置对齐", target: self, action: #selector(resetAlignment))
        addArrangedSubview(row([visible, guides, reset]))

        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.isContinuous = true
        opacitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        opacitySlider.setAccessibilityLabel("参照不透明度")
        addArrangedSubview(row([NSTextField(labelWithString: "参照不透明度"), opacitySlider, opacityLabel]))

        canvas.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.widthAnchor.constraint(equalTo: widthAnchor),
            canvas.heightAnchor.constraint(equalToConstant: 320)
        ])
        sizeEditor.orientation = .vertical
        sizeEditor.alignment = .leading
        sizeEditor.spacing = 8
        addArrangedSubview(sizeEditor)

        frameSlider.target = self
        frameSlider.action = #selector(frameChanged)
        frameSlider.isContinuous = true
        frameSlider.widthAnchor.constraint(equalToConstant: 215).isActive = true
        frameSlider.setAccessibilityLabel("标定当前帧")
        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        addArrangedSubview(row([NSTextField(labelWithString: "当前帧"), frameSlider, frameLabel]))

        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged)
        zoomSlider.isContinuous = true
        zoomSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        zoomSlider.setAccessibilityLabel("标定画布缩放")
        addArrangedSubview(row([NSTextField(labelWithString: "画布缩放"), zoomSlider, zoomLabel]))

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemOrange
        statusLabel.preferredMaxLayoutWidth = 400
        addArrangedSubview(statusLabel)
        let hint = NSTextField(wrappingLabelWithString: "拖动实色猫对齐轮廓；片段倍率即时保存。画布缩放同时作用于两只猫，不改变实际大小。参照固定为选定时的首帧与倍率。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 400
        addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setBatchState(busy: Bool, canUndo: Bool) {
        batchButton.title = busy ? "正在分析首帧…" : "首帧批量标定…"
        batchButton.isEnabled = !busy
        undoBatchButton.isEnabled = !busy && canUndo
    }

    @objc private func batchCalibrationRequested() {
        guard let reference else { return }
        onBatchCalibration?(reference)
    }

    @objc private func undoBatchCalibrationRequested() { onUndoBatchCalibration?() }

    /// Keep scale controls next to the bottom of the canvas in a short viewport.
    func setSizeEditor(_ editor: NSView) {
        for view in sizeEditor.arrangedSubviews {
            sizeEditor.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        sizeEditor.addArrangedSubview(editor)
    }

    func configure(clip: PetClip, all: [PetClip], globalScale: Double) {
        let changedClip = current?.id != clip.id
        let changedGlobal = self.globalScale != globalScale
        current = clip
        self.globalScale = globalScale
        clips = all.filter { $0.libraryTab == .cats }
        let preferred = reference?.id ?? defaults.string(forKey: Self.referenceKey)
        let resolved = ClipCalibrationGeometry.referenceID(preferred: preferred, available: clips.map(\.id))
        referencePopup.removeAllItems()
        for (index, item) in clips.enumerated() {
            referencePopup.addItem(withTitle: item.displayTitle(indexInLibrary: all.firstIndex(where: { $0.id == item.id }) ?? index))
            referencePopup.lastItem?.representedObject = item.id
        }
        if let resolved, let index = clips.firstIndex(where: { $0.id == resolved }) {
            referencePopup.selectItem(at: index)
        }
        let changedReference = reference?.id != resolved
        if changedReference {
            captureReference(id: resolved)
        }
        if changedClip {
            frameIndex = 1
            canvas.offset = .zero
        }
        frameIndex = min(max(1, clip.frameCount), frameIndex)
        frameSlider.minValue = 1
        frameSlider.maxValue = Double(max(1, clip.frameCount))
        frameSlider.isEnabled = clip.frameCount > 1
        loadCurrentFrame()
        updateSizes()
        if changedClip || changedReference || changedGlobal { fitViewport() }
    }

    func setClipScale(_ scale: Double) {
        current?.clipScale = scale
        if let index = clips.firstIndex(where: { $0.id == current?.id }) {
            clips[index].clipScale = scale
        }
        updateSizes()
    }

    /// Clears current material without discarding the reference snapshot.
    func clearCurrent() {
        current = nil
        clips = []
        canvas.currentImage = nil
        canvas.needsDisplay = true
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func captureReference(id: String?) {
        reference = clips.first { $0.id == id }
        if let reference {
            defaults.set(reference.id, forKey: Self.referenceKey)
            canvas.referenceImage = NSImage(contentsOf: AppPaths.frameURL(clipID: reference.id, index: 1))
        } else {
            defaults.removeObject(forKey: Self.referenceKey)
            canvas.referenceImage = nil
        }
    }

    private func loadCurrentFrame() {
        guard let current else { return }
        canvas.currentImage = ClipMedia.image(id: current.id, index: frameIndex, fps: current.fps)
        frameSlider.doubleValue = Double(frameIndex)
        frameLabel.stringValue = "\(frameIndex) / \(max(1, current.frameCount)) 帧"
        updateStatus()
    }

    private func updateSizes() {
        canvas.currentSize = current?.effectiveDisplaySize(globalScale: globalScale) ?? .zero
        canvas.referenceSize = reference?.effectiveDisplaySize(globalScale: globalScale) ?? .zero
        if let reference {
            referenceInfo.stringValue = String(format: "参照快照 %.2f× · %.0f × %.0f pt", reference.clipScale, canvas.referenceSize.width, canvas.referenceSize.height)
        } else {
            referenceInfo.stringValue = "没有可用的猫猫参照"
        }
        updateStatus()
        canvas.needsDisplay = true
    }

    private func updateStatus() {
        var messages: [String] = []
        if canvas.referenceImage == nil { messages.append("参照首帧缺失，请选择其他片段或重新导入。") }
        if canvas.currentImage == nil { messages.append("当前帧缺失，请切换帧或重新导入。") }
        if !PetClipPresentationPolicy.isValidDisplaySize(canvas.currentSize)
            || !PetClipPresentationPolicy.isValidDisplaySize(canvas.referenceSize) {
            messages.append("素材尺寸无效，无法准确标定。")
        }
        statusLabel.stringValue = messages.joined(separator: " ")
        statusLabel.isHidden = messages.isEmpty
    }

    private func fitViewport() {
        canvas.baseScale = ClipCalibrationGeometry.fitScale(current: canvas.currentSize, reference: canvas.referenceSize, canvas: CGSize(width: 400, height: 320))
        zoomSlider.doubleValue = 1
        zoomChanged()
    }

    @objc private func referenceChanged() {
        captureReference(id: referencePopup.selectedItem?.representedObject as? String)
        canvas.offset = .zero
        updateSizes()
        fitViewport()
    }

    @objc private func refreshReference() {
        captureReference(id: reference?.id)
        updateSizes()
        fitViewport()
    }

    @objc private func frameChanged() {
        guard let current else { return }
        frameIndex = min(max(1, current.frameCount), max(1, Int(frameSlider.doubleValue.rounded())))
        loadCurrentFrame()
        canvas.needsDisplay = true
    }

    @objc private func opacityChanged() {
        canvas.referenceOpacity = opacitySlider.doubleValue
        opacityLabel.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
        canvas.needsDisplay = true
    }

    @objc private func zoomChanged() {
        canvas.zoom = zoomSlider.doubleValue
        zoomLabel.stringValue = "\(Int((zoomSlider.doubleValue * 100).rounded()))%"
        canvas.needsDisplay = true
    }

    @objc private func visibilityChanged(_ sender: NSButton) {
        canvas.showsReference = sender.state == .on
        canvas.needsDisplay = true
    }

    @objc private func guidesChanged(_ sender: NSButton) {
        canvas.showsGuides = sender.state == .on
        canvas.needsDisplay = true
    }

    @objc private func resetAlignment() {
        canvas.offset = .zero
        canvas.needsDisplay = true
    }
}

@MainActor
private final class ClipCalibrationCanvas: NSView {
    var currentImage: NSImage?
    var referenceImage: NSImage?
    var currentSize: CGSize = .zero
    var referenceSize: CGSize = .zero
    var baseScale: CGFloat = 1
    var zoom: CGFloat = 1
    var offset: CGPoint = .zero
    var referenceOpacity: CGFloat = 0.3
    var showsReference = true
    var showsGuides = true
    private var dragPoint: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityLabel("尺寸标定画布，可拖动当前猫调整对照位置")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let tile: CGFloat = 16
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        for y in 0..<Int(ceil(bounds.height / tile)) {
            for x in 0..<Int(ceil(bounds.width / tile)) where (x + y) % 2 == 0 {
                NSRect(x: CGFloat(x) * tile, y: CGFloat(y) * tile, width: tile, height: tile).fill()
            }
        }
        NSGraphicsContext.current?.imageInterpolation = .high
        let scale = drawingScale
        let currentOffset = CGPoint(x: offset.x * scale, y: offset.y * scale)
        let currentRect = ClipCalibrationGeometry.imageRect(size: currentSize, canvas: bounds.size, scale: scale, offset: currentOffset)
        currentImage?.draw(in: currentRect, from: .zero, operation: .sourceOver, fraction: 1)
        // Draw the ghost last so it remains visible over opaque current pixels.
        if showsReference {
            let rect = ClipCalibrationGeometry.imageRect(size: referenceSize, canvas: bounds.size, scale: scale)
            referenceImage?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: referenceOpacity)
        }
        if showsGuides {
            NSColor.systemTeal.withAlphaComponent(0.8).setStroke()
            let lines = NSBezierPath()
            lines.setLineDash([4, 4], count: 2, phase: 0)
            lines.move(to: NSPoint(x: bounds.midX, y: 0))
            lines.line(to: NSPoint(x: bounds.midX, y: bounds.height))
            lines.move(to: NSPoint(x: 0, y: ClipCalibrationGeometry.baseline))
            lines.line(to: NSPoint(x: bounds.width, y: ClipCalibrationGeometry.baseline))
            lines.stroke()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let previous = dragPoint else { return }
        let scale = drawingScale
        guard scale.isFinite, scale > 0 else { return }
        offset.x += (point.x - previous.x) / scale
        offset.y += (point.y - previous.y) / scale
        dragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragPoint = nil
    }

    /// Resizing the library scales both images together without fitting either separately.
    private var drawingScale: CGFloat {
        baseScale * zoom * min(bounds.width / 400, bounds.height / 320)
    }
}
