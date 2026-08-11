import AppKit

/// Modal sheet: preview chromakey on sample frames, tune parameters, accept or cancel.
@MainActor
final class ChromaKeyPreviewController: NSWindowController {
    private let staging: ImportStaging
    private var settings: ChromaKeySettings
    private var continuation: CheckedContinuation<ChromaKeySettings?, Never>?

    private let previewStack = NSStackView()
    private let similaritySlider = NSSlider()
    private let blendSlider = NSSlider()
    private let despillSlider = NSSlider()
    private let similarityValue = NSTextField(labelWithString: "")
    private let blendValue = NSTextField(labelWithString: "")
    private let despillValue = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "正在生成预览…")
    private let spinner = NSProgressIndicator()
    private var debounceWork: DispatchWorkItem?
    private var previewGeneration = 0
    private let previewDir: URL

    init(staging: ImportStaging, initial: ChromaKeySettings = .default) {
        self.staging = staging
        self.settings = initial.clamped()
        self.previewDir = AppPaths.supportRoot
            .appendingPathComponent("preview-cache", isDirectory: true)
            .appendingPathComponent(staging.clipID, isDirectory: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "抠绿幕预览 · \(staging.displayName)"
        super.init(window: window)
        buildUI()
        refreshValueLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Present as a sheet and wait for Accept (settings) or Cancel (nil).
    func runModal(for parent: NSWindow) async -> ChromaKeySettings? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            parent.beginSheet(window!) { _ in }
            schedulePreview(immediate: true)
        }
    }

    private func finish(_ result: ChromaKeySettings?) {
        debounceWork?.cancel()
        try? FileManager.default.removeItem(at: previewDir)
        if let parent = window?.sheetParent {
            parent.endSheet(window!)
        } else {
            window?.close()
        }
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let hint = NSTextField(wrappingLabelWithString: "拖动滑块调整抠图效果。满意后点「接受并导入」才会导出完整透明帧；点「取消」丢弃本次导入。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 720
        root.addArrangedSubview(hint)

        previewStack.orientation = .horizontal
        previewStack.spacing = 12
        previewStack.distribution = .fillEqually
        previewStack.setContentHuggingPriority(.defaultLow, for: .vertical)
        previewStack.heightAnchor.constraint(equalToConstant: 260).isActive = true
        root.addArrangedSubview(previewStack)

        for _ in 0..<3 {
            previewStack.addArrangedSubview(makePreviewSlot(title: "—"))
        }

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(NSView())
        root.addArrangedSubview(statusRow)

        root.addArrangedSubview(makeSliderRow(
            title: "抠图强度",
            detail: "越大越容易把边缘连通的绿色当绿幕；主体内部即使偏绿也不会被扣",
            slider: similaritySlider,
            valueLabel: similarityValue,
            min: 0.04, max: 0.50, value: settings.similarity
        ))
        root.addArrangedSubview(makeSliderRow(
            title: "边缘羽化",
            detail: "只柔化轮廓一圈，不会让主体变透明",
            slider: blendSlider,
            valueLabel: blendValue,
            min: 0.0, max: 0.35, value: settings.blend
        ))
        root.addArrangedSubview(makeSliderRow(
            title: "去绿边",
            detail: "只处理轮廓附近的溢色",
            slider: despillSlider,
            valueLabel: despillValue,
            min: 0.0, max: 0.85, value: settings.despillMix
        ))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelImport))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let accept = NSButton(title: "接受并导入", target: self, action: #selector(acceptImport))
        accept.bezelStyle = .rounded
        accept.keyEquivalent = "\r"
        buttons.addArrangedSubview(reset)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(accept)
        root.addArrangedSubview(buttons)
    }

    private func makePreviewSlot(title: String) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .centerX
        box.spacing = 6

        let checker = CheckerboardImageView()
        checker.translatesAutoresizingMaskIntoConstraints = false
        checker.heightAnchor.constraint(equalToConstant: 220).isActive = true
        checker.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        checker.wantsLayer = true
        checker.layer?.cornerRadius = 8
        checker.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        box.addArrangedSubview(checker)
        box.addArrangedSubview(label)
        box.identifier = NSUserInterfaceItemIdentifier(title)
        return box
    }

    private func makeSliderRow(
        title: String,
        detail: String,
        slider: NSSlider,
        valueLabel: NSTextField,
        min: Double,
        max: Double,
        value: Double
    ) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2

        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 8
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        head.addArrangedSubview(titleField)
        head.addArrangedSubview(NSView())
        head.addArrangedSubview(valueLabel)

        let tip = NSTextField(labelWithString: detail)
        tip.font = .systemFont(ofSize: 10)
        tip.textColor = .tertiaryLabelColor

        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true

        col.addArrangedSubview(head)
        col.addArrangedSubview(tip)
        col.addArrangedSubview(slider)
        return col
    }

    private func refreshValueLabels() {
        similarityValue.stringValue = String(format: "%.2f", settings.similarity)
        blendValue.stringValue = String(format: "%.2f", settings.blend)
        despillValue.stringValue = String(format: "%.2f", settings.despillMix)
    }

    private func readSettingsFromSliders() {
        settings.similarity = similaritySlider.doubleValue
        settings.blend = blendSlider.doubleValue
        settings.despillMix = despillSlider.doubleValue
        settings = settings.clamped()
        refreshValueLabels()
    }

    @objc private func sliderChanged() {
        readSettingsFromSliders()
        schedulePreview(immediate: false)
    }

    @objc private func resetDefaults() {
        settings = .default
        similaritySlider.doubleValue = settings.similarity
        blendSlider.doubleValue = settings.blend
        despillSlider.doubleValue = settings.despillMix
        refreshValueLabels()
        schedulePreview(immediate: true)
    }

    @objc private func cancelImport() {
        finish(nil)
    }

    @objc private func acceptImport() {
        readSettingsFromSliders()
        finish(settings)
    }

    private func schedulePreview(immediate: Bool) {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.regeneratePreview()
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0.05 : 0.28), execute: work)
    }

    private func regeneratePreview() {
        previewGeneration += 1
        let generation = previewGeneration
        let settingsSnapshot = settings
        let staging = staging
        let previewDir = previewDir

        spinner.startAnimation(nil)
        statusLabel.stringValue = "正在生成预览…"

        Task.detached(priority: .userInitiated) {
            do {
                let urls = try ChromaKeyProcessor.shared.renderPreviewFrames(
                    localSourceURL: staging.localSourceURL,
                    settings: settingsSnapshot,
                    outputDirectory: previewDir,
                    duration: staging.duration
                )
                let images = urls.compactMap { NSImage(contentsOf: $0) }
                await MainActor.run {
                    guard generation == self.previewGeneration else { return }
                    self.applyPreviewImages(images)
                    self.spinner.stopAnimation(nil)
                    self.statusLabel.stringValue = "预览已更新 · 前 / 中 / 后 三帧"
                }
            } catch {
                await MainActor.run {
                    guard generation == self.previewGeneration else { return }
                    self.spinner.stopAnimation(nil)
                    self.statusLabel.stringValue = "预览失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func applyPreviewImages(_ images: [NSImage]) {
        let labels = ["前段", "中段", "后段"]
        let slots = previewStack.arrangedSubviews
        for (i, slot) in slots.enumerated() {
            guard let stack = slot as? NSStackView else { continue }
            let checker = stack.arrangedSubviews.first as? CheckerboardImageView
            let label = stack.arrangedSubviews.last as? NSTextField
            label?.stringValue = labels[safe: i] ?? "预览"
            checker?.image = images[safe: i]
        }
    }
}

private final class CheckerboardImageView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let tile: CGFloat = 10
        for y in stride(from: 0, to: bounds.height, by: tile) {
            for x in stride(from: 0, to: bounds.width, by: tile) {
                let odd = Int((x + y) / tile) % 2 == 0
                (odd ? NSColor.gray.withAlphaComponent(0.25) : NSColor.gray.withAlphaComponent(0.12)).setFill()
                NSRect(x: x, y: y, width: tile, height: tile).fill()
            }
        }
        guard let image else { return }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
        let origin = NSPoint(
            x: (bounds.width - drawSize.width) / 2,
            y: (bounds.height - drawSize.height) / 2
        )
        image.draw(in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver, fraction: 1)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
