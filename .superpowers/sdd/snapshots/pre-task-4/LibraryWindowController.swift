import AppKit
import UniformTypeIdentifiers

@MainActor
final class LibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: LibraryStore
    private let engine: PlaylistEngine

    private let table = NSTableView()
    private let detail = DetailPanel()
    private let countLabel = NSTextField(labelWithString: "共 0 个片段")
    private let modePopup = NSPopUpButton()
    private let scaleSlider = NSSlider()
    private let topToggle = NSButton(checkboxWithTitle: "置顶", target: nil, action: nil)
    private let clickToggle = NSButton(checkboxWithTitle: "点击穿透", target: nil, action: nil)
    private let launchAtLoginToggle = NSButton(checkboxWithTitle: "开机启动", target: nil, action: nil)
    private let autoLinkToggle = NSButton(checkboxWithTitle: "自动衔接", target: nil, action: nil)
    private let thresholdSlider = NSSlider()
    private let progressOverlay = ProgressOverlay()
    private var isImporting = false
    private var suppressSelectionSideEffects = false

    init(store: LibraryStore, engine: PlaylistEngine) {
        self.store = store
        self.engine = engine

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "桌面宠物 · 片段库"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        super.init(window: window)

        buildUI()
        reload()
        NotificationCenter.default.addObserver(
            forName: .libraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload(preservingSelection: true) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Explicit top / middle / bottom regions — avoids NSStackView overlap.
        let toolbar = makeToolbar()
        let settings = makeSettings()
        let body = makeBody()

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        settings.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbar)
        content.addSubview(body)
        content.addSubview(settings)

        // Settings hug their content; body fills leftover space.
        toolbar.setContentHuggingPriority(.required, for: .vertical)
        toolbar.setContentCompressionResistancePriority(.required, for: .vertical)
        settings.setContentHuggingPriority(.required, for: .vertical)
        settings.setContentCompressionResistancePriority(.required, for: .vertical)
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        body.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            settings.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            settings.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            settings.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            body.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: settings.topAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])

        progressOverlay.translatesAutoresizingMaskIntoConstraints = false
        progressOverlay.isHidden = true
        content.addSubview(progressOverlay)
        NSLayoutConstraint.activate([
            progressOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progressOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progressOverlay.topAnchor.constraint(equalTo: content.topAnchor),
            progressOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func makeToolbar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let addBtn = NSButton(title: "添加视频…", target: self, action: #selector(addVideos))
        addBtn.bezelStyle = .rounded
        let selectAllBtn = NSButton(title: "全选", target: self, action: #selector(selectAllClips))
        selectAllBtn.bezelStyle = .rounded
        let clearSelBtn = NSButton(title: "取消全选", target: self, action: #selector(clearSelection))
        clearSelBtn.bezelStyle = .rounded
        let upBtn = NSButton(title: "上移", target: self, action: #selector(moveSelectionUp))
        upBtn.bezelStyle = .rounded
        let downBtn = NSButton(title: "下移", target: self, action: #selector(moveSelectionDown))
        downBtn.bezelStyle = .rounded
        let playBtn = NSButton(title: "按所选播放", target: self, action: #selector(playSelectedQueue))
        playBtn.bezelStyle = .rounded
        let clearQueueBtn = NSButton(title: "清除队列", target: self, action: #selector(clearPlayQueue))
        clearQueueBtn.bezelStyle = .rounded
        let deleteBtn = NSButton(title: "删除", target: self, action: #selector(deleteSelected))
        deleteBtn.bezelStyle = .rounded
        let rebuildBtn = NSButton(title: "重算衔接", target: self, action: #selector(rebuildLinks))
        rebuildBtn.bezelStyle = .rounded
        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor

        row.addArrangedSubview(addBtn)
        row.addArrangedSubview(selectAllBtn)
        row.addArrangedSubview(clearSelBtn)
        row.addArrangedSubview(upBtn)
        row.addArrangedSubview(downBtn)
        row.addArrangedSubview(playBtn)
        row.addArrangedSubview(clearQueueBtn)
        row.addArrangedSubview(deleteBtn)
        row.addArrangedSubview(rebuildBtn)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(countLabel)
        bar.addSubview(row)

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -8),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52)
        ])
        return bar
    }

    private func makeBody() -> NSView {
        let body = NSView()
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let listPane = NSView()
        listPane.translatesAutoresizingMaskIntoConstraints = false
        listPane.wantsLayer = true
        listPane.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let listHeader = NSTextField(labelWithString: "片段列表")
        listHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        listHeader.textColor = .secondaryLabelColor
        listHeader.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = table

        table.headerView = nil
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.width = 250
        col.minWidth = 180
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 72
        table.doubleAction = #selector(playSelectedQueue)
        table.target = self
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 4)

        listPane.addSubview(listHeader)
        listPane.addSubview(scroll)
        NSLayoutConstraint.activate([
            listHeader.topAnchor.constraint(equalTo: listPane.topAnchor, constant: 10),
            listHeader.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 12),
            listHeader.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: listHeader.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: listPane.bottomAnchor)
        ])

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.onToggleNext = { [weak self] clipID, nextID, enabled in
            guard let self else { return }
            guard let clip = self.store.clip(id: clipID) else { return }
            var set = Set(clip.nextClipIDs)
            if enabled { set.insert(nextID) } else { set.remove(nextID) }
            self.store.setNextClips(for: clipID, nextIDs: Array(set))
            self.detail.show(
                clip: self.store.clip(id: clipID),
                all: self.store.state.clips,
                threshold: self.store.state.autoLinkThreshold
            )
        }
        detail.onRename = { [weak self] clipID, newName in
            guard let self else { return }
            self.store.renameClip(id: clipID, to: newName)
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            self.reload(preservingSelection: true)
        }

        body.addSubview(listPane)
        body.addSubview(divider)
        body.addSubview(detail)

        NSLayoutConstraint.activate([
            listPane.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            listPane.topAnchor.constraint(equalTo: body.topAnchor),
            listPane.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            listPane.widthAnchor.constraint(equalToConstant: 360),

            divider.leadingAnchor.constraint(equalTo: listPane.trailingAnchor),
            divider.topAnchor.constraint(equalTo: body.topAnchor),
            divider.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            detail.topAnchor.constraint(equalTo: body.topAnchor),
            detail.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])

        return body
    }

    private func makeSettings() -> NSView {
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)

        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false

        let row1 = NSStackView()
        row1.orientation = .horizontal
        row1.spacing = 12
        let modeLabel = NSTextField(labelWithString: "播放模式")
        modePopup.removeAllItems()
        for mode in PlaybackMode.allCases {
            modePopup.addItem(withTitle: mode.title)
            modePopup.lastItem?.representedObject = mode.rawValue
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        topToggle.target = self
        topToggle.action = #selector(windowFlagsChanged)
        clickToggle.target = self
        clickToggle.action = #selector(windowFlagsChanged)
        launchAtLoginToggle.target = self
        launchAtLoginToggle.action = #selector(launchAtLoginChanged)
        row1.addArrangedSubview(modeLabel)
        row1.addArrangedSubview(modePopup)
        row1.addArrangedSubview(topToggle)
        row1.addArrangedSubview(clickToggle)
        row1.addArrangedSubview(launchAtLoginToggle)
        row1.addArrangedSubview(NSView())

        let row2 = NSStackView()
        row2.orientation = .horizontal
        row2.spacing = 12
        let scaleLabel = NSTextField(labelWithString: "大小")
        scaleSlider.minValue = 0.4
        scaleSlider.maxValue = 2.2
        scaleSlider.doubleValue = store.state.petScale
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged)
        scaleSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        autoLinkToggle.target = self
        autoLinkToggle.action = #selector(autoLinkChanged)
        let thrLabel = NSTextField(labelWithString: "相似度阈值")
        thresholdSlider.minValue = 0.5
        thresholdSlider.maxValue = 0.95
        thresholdSlider.doubleValue = store.state.autoLinkThreshold
        thresholdSlider.target = self
        thresholdSlider.action = #selector(thresholdChanged)
        thresholdSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        row2.addArrangedSubview(scaleLabel)
        row2.addArrangedSubview(scaleSlider)
        row2.addArrangedSubview(autoLinkToggle)
        row2.addArrangedSubview(thrLabel)
        row2.addArrangedSubview(thresholdSlider)
        row2.addArrangedSubview(NSView())

        let launchHint = NSTextField(wrappingLabelWithString: "「开机启动」会在登录时自动打开桌面宠物。若提示需要批准，请到 系统设置 → 通用 → 登录项 中允许。")
        launchHint.textColor = .secondaryLabelColor
        launchHint.font = .systemFont(ofSize: 11)
        launchHint.preferredMaxLayoutWidth = 820

        col.addArrangedSubview(row1)
        col.addArrangedSubview(row2)
        col.addArrangedSubview(launchHint)
        wrap.addSubview(col)

        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),

            col.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 10),
            col.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
            col.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
            col.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),

            wrap.heightAnchor.constraint(equalToConstant: 110)
        ])
        return wrap
    }

    func reload(preservingSelection: Bool = false) {
        let selectedIDs: [String]
        if preservingSelection {
            selectedIDs = selectedClips().map(\.id)
        } else {
            selectedIDs = selectedClip().map { [$0.id] } ?? []
        }

        let count = store.state.clips.count
        let selectedCount = table.numberOfSelectedRows
        let queueCount = store.state.activeQueue.count
        let queueText = queueCount > 0 ? " · 队列 \(queueCount)" : ""
        countLabel.stringValue = "已选 \(max(selectedCount, selectedIDs.count)) / 共 \(count)\(queueText)"
        window?.title = "桌面宠物 · 片段库（\(count)）"

        suppressSelectionSideEffects = true
        table.reloadData()
        if !selectedIDs.isEmpty {
            var indices = IndexSet()
            for id in selectedIDs {
                if let idx = store.state.clips.firstIndex(where: { $0.id == id }) {
                    indices.insert(idx)
                }
            }
            table.selectRowIndexes(indices, byExtendingSelection: false)
        }
        suppressSelectionSideEffects = false

        modePopup.selectItem(at: PlaybackMode.allCases.firstIndex(of: store.state.playbackMode) ?? 0)
        topToggle.state = store.state.alwaysOnTop ? .on : .off
        clickToggle.state = store.state.clickThrough ? .on : .off
        launchAtLoginToggle.state = LaunchAtLogin.isEnabled ? .on : .off
        autoLinkToggle.state = store.state.autoLinkEnabled ? .on : .off
        scaleSlider.doubleValue = store.state.petScale
        thresholdSlider.doubleValue = store.state.autoLinkThreshold
        thresholdSlider.isEnabled = store.state.autoLinkEnabled

        updateImportOverlay()
        updateCountLabel()

        if let err = store.lastError {
            store.lastError = nil
            let alert = NSAlert()
            alert.messageText = "导入失败"
            alert.informativeText = err
            if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
        }

        showSelectedDetail()
    }

    private func updateCountLabel() {
        let count = store.state.clips.count
        let selectedCount = table.selectedRowIndexes.count
        let queueCount = store.state.activeQueue.count
        let queueText = queueCount > 0 ? " · 队列 \(queueCount)" : " · 播放全部"
        countLabel.stringValue = "已选 \(selectedCount) / 共 \(count)\(queueText)"
        countLabel.textColor = .secondaryLabelColor
    }

    func tickImportProgress() {
        updateImportOverlay()
    }

    private func updateImportOverlay() {
        if let progress = store.importProgress {
            progressOverlay.isHidden = false
            progressOverlay.alphaValue = 1
            progressOverlay.update(progress)
        } else {
            progressOverlay.isHidden = true
            progressOverlay.alphaValue = 0
        }
    }

    private func selectedClip() -> PetClip? {
        selectedClips().last
    }

    private func selectedClips() -> [PetClip] {
        table.selectedRowIndexes.sorted().compactMap { row in
            guard row >= 0, row < store.state.clips.count else { return nil }
            return store.state.clips[row]
        }
    }

    private func selectClip(id: String) {
        guard let idx = store.state.clips.firstIndex(where: { $0.id == id }) else { return }
        suppressSelectionSideEffects = true
        table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        table.scrollRowToVisible(idx)
        suppressSelectionSideEffects = false
        updateCountLabel()
        showSelectedDetail()
    }

    private func showSelectedDetail() {
        let selected = selectedClips()
        if selected.count > 1 {
            detail.showMultiple(selected: selected, queue: store.state.activeQueue)
        } else {
            detail.show(clip: selected.first, all: store.state.clips, threshold: store.state.autoLinkThreshold)
        }
    }

    // MARK: Actions

    @objc private func selectAllClips() {
        suppressSelectionSideEffects = true
        table.selectAll(nil)
        suppressSelectionSideEffects = false
        updateCountLabel()
        showSelectedDetail()
    }

    @objc private func clearSelection() {
        suppressSelectionSideEffects = true
        table.deselectAll(nil)
        suppressSelectionSideEffects = false
        updateCountLabel()
        showSelectedDetail()
    }

    @objc private func moveSelectionUp() {
        let indices = table.selectedRowIndexes
        guard !indices.isEmpty else { return }
        let next = store.moveClipsUp(at: indices)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        suppressSelectionSideEffects = true
        table.reloadData()
        table.selectRowIndexes(next, byExtendingSelection: false)
        if let first = next.first { table.scrollRowToVisible(first) }
        suppressSelectionSideEffects = false
        updateCountLabel()
        showSelectedDetail()
    }

    @objc private func moveSelectionDown() {
        let indices = table.selectedRowIndexes
        guard !indices.isEmpty else { return }
        let next = store.moveClipsDown(at: indices)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        suppressSelectionSideEffects = true
        table.reloadData()
        table.selectRowIndexes(next, byExtendingSelection: false)
        if let last = next.max() { table.scrollRowToVisible(last) }
        suppressSelectionSideEffects = false
        updateCountLabel()
        showSelectedDetail()
    }

    @objc private func playSelectedQueue() {
        let selected = selectedClips()
        guard !selected.isEmpty else { return }
        let ids = selected.map(\.id)
        store.setActiveQueue(ids)
        // Keep the user's current playback mode (sequential / random / graph).
        engine.playFromQueueStart()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        reload(preservingSelection: true)
    }

    @objc private func clearPlayQueue() {
        store.clearActiveQueue()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        reload(preservingSelection: true)
    }

    @objc private func addVideos() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                self.isImporting = true
                defer { self.isImporting = false }
                var lastID: String?
                var importedCount = 0

                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }

                    self.store.importProgress = ImportProgress(
                        clipName: url.lastPathComponent,
                        fraction: 0,
                        message: "正在准备视频…"
                    )
                    self.updateImportOverlay()

                    let staging: ImportStaging
                    do {
                        staging = try self.store.prepareStaging(from: url)
                    } catch {
                        self.store.importProgress = nil
                        self.store.lastError = error.localizedDescription
                        self.reload()
                        continue
                    }

                    self.store.importProgress = nil
                    self.updateImportOverlay()

                    // Preview & tune chromakey before committing.
                    let preview = ChromaKeyPreviewController(staging: staging)
                    guard let settings = await preview.runModal(for: self.window!),
                          let parentWindow = self.window else {
                        self.store.discardStaging(staging)
                        continue
                    }
                    _ = parentWindow

                    self.store.importProgress = ImportProgress(
                        clipName: staging.displayName,
                        fraction: 0.2,
                        message: "正在导出透明帧…"
                    )
                    self.updateImportOverlay()

                    if let clip = await self.store.commitImport(staging: staging, settings: settings) {
                        importedCount += 1
                        lastID = clip.id
                        self.reload()
                        self.selectClip(id: clip.id)
                        self.engine.playClip(id: clip.id)
                        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                    } else {
                        self.reload()
                    }
                }

                self.store.importProgress = nil
                self.reload()
                if let lastID { self.selectClip(id: lastID) }

                if importedCount > 0 {
                    let alert = NSAlert()
                    alert.messageText = "导入完成"
                    alert.informativeText = "成功导入 \(importedCount) 个片段，当前共 \(self.store.state.clips.count) 个。"
                    if let window = self.window {
                        alert.beginSheetModal(for: window) { _ in }
                    } else {
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func deleteSelected() {
        let selected = selectedClips()
        guard !selected.isEmpty else { return }
        let names = selected.prefix(3).map { clip in
            let idx = store.state.clips.firstIndex(where: { $0.id == clip.id }) ?? 0
            return clip.displayTitle(indexInLibrary: idx)
        }.joined(separator: "、")
        let more = selected.count > 3 ? " 等 \(selected.count) 个" : ""
        let alert = NSAlert()
        alert.messageText = "删除片段"
        alert.informativeText = "确定删除 \(names)\(more)？"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeClips(ids: selected.map(\.id))
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        reload()
    }

    @objc private func rebuildLinks() {
        let linkCount = store.rebuildAutoLinks()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        reload(preservingSelection: true)
        let thresholdPct = Int((store.state.autoLinkThreshold * 100).rounded())
        if linkCount == 0 {
            countLabel.stringValue = "重算完成：未匹配到衔接（当前阈值 \(thresholdPct)%，可调低后再试）"
        } else {
            countLabel.stringValue = "重算完成：共写入 \(linkCount) 条衔接（阈值 \(thresholdPct)%）"
        }
        countLabel.textColor = .labelColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.updateCountLabel()
        }
    }

    @objc private func modeChanged() {
        guard let raw = modePopup.selectedItem?.representedObject as? String,
              let mode = PlaybackMode(rawValue: raw) else { return }
        store.update { $0.playbackMode = mode }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    @objc private func windowFlagsChanged() {
        store.update {
            $0.alwaysOnTop = topToggle.state == .on
            $0.clickThrough = clickToggle.state == .on
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    @objc private func launchAtLoginChanged() {
        let wantEnabled = launchAtLoginToggle.state == .on
        if let error = LaunchAtLogin.setEnabled(wantEnabled) {
            launchAtLoginToggle.state = LaunchAtLogin.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "无法设置开机启动"
            alert.informativeText = error + "\n\n当前状态：\(LaunchAtLogin.statusDescription)\n请确认是通过 DesktopPet.app 启动的；若系统要求批准，可打开登录项设置。"
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "打开登录项设置")
            let result = alert.runModal()
            if result == .alertSecondButtonReturn {
                LaunchAtLogin.openLoginItemsSettings()
            }
            return
        }

        // macOS may leave status as requiresApproval until the user confirms.
        launchAtLoginToggle.state = LaunchAtLogin.isEnabled ? .on : .off
        if wantEnabled && LaunchAtLogin.requiresApproval {
            let alert = NSAlert()
            alert.messageText = "需要系统批准"
            alert.informativeText = "请到「系统设置 → 通用 → 登录项」中允许 DesktopPet。"
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                LaunchAtLogin.openLoginItemsSettings()
            }
        }
    }

    @objc private func scaleChanged() {
        store.update { $0.petScale = scaleSlider.doubleValue }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    @objc private func autoLinkChanged() {
        store.update { $0.autoLinkEnabled = autoLinkToggle.state == .on }
        if store.state.autoLinkEnabled {
            store.rebuildAutoLinks()
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        showSelectedDetail()
    }

    @objc private func thresholdChanged() {
        store.update { $0.autoLinkThreshold = thresholdSlider.doubleValue }
        if store.state.autoLinkEnabled {
            store.rebuildAutoLinks()
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        showSelectedDetail()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.state.clips.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = store.state.clips[row]
        let id = NSUserInterfaceItemIdentifier("clipCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ClipTableCellView) ?? {
            let c = ClipTableCellView()
            c.identifier = id
            return c
        }()

        let title = clip.displayTitle(indexInLibrary: row)
        let playing = engine.currentClipID == clip.id
        let queueIndex = store.state.activeQueue.firstIndex(of: clip.id).map { $0 + 1 }
        cell.configure(
            title: title,
            meta: clip.metaText,
            firstFrame: AppPaths.frameURL(clipID: clip.id, index: 1),
            lastFrame: AppPaths.frameURL(clipID: clip.id, index: max(1, clip.frameCount)),
            queueIndex: queueIndex,
            isPlaying: playing
        )
        cell.toolTip = "\(title)\n导入：\(clip.importedAtText)\n\(clip.frameCount) 帧 · \(String(format: "%.1f", clip.duration)) 秒"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionSideEffects else { return }
        updateCountLabel()
        showSelectedDetail()
    }
}

// MARK: - Rich list cell

@MainActor
final class ClipTableCellView: NSTableCellView {
    private let firstThumb = NSImageView()
    private let lastThumb = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        for thumb in [firstThumb, lastThumb] {
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.imageScaling = .scaleProportionallyUpOrDown
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = 6
            thumb.layer?.masksToBounds = true
            thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            thumb.layer?.borderWidth = 0.5
            thumb.layer?.borderColor = NSColor.separatorColor.cgColor
            addSubview(thumb)
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .systemBlue
        badgeLabel.isHidden = true
        addSubview(badgeLabel)

        let thumbSize: CGFloat = 52
        NSLayoutConstraint.activate([
            firstThumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            firstThumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            firstThumb.widthAnchor.constraint(equalToConstant: thumbSize),
            firstThumb.heightAnchor.constraint(equalToConstant: thumbSize),

            lastThumb.leadingAnchor.constraint(equalTo: firstThumb.trailingAnchor, constant: 4),
            lastThumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            lastThumb.widthAnchor.constraint(equalToConstant: thumbSize),
            lastThumb.heightAnchor.constraint(equalToConstant: thumbSize),

            titleLabel.leadingAnchor.constraint(equalTo: lastThumb.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            badgeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgeLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 2)
        ])
    }

    func configure(
        title: String,
        meta: String,
        firstFrame: URL,
        lastFrame: URL,
        queueIndex: Int?,
        isPlaying: Bool
    ) {
        titleLabel.stringValue = title + (isPlaying ? "  ▶" : "")
        metaLabel.stringValue = meta
        firstThumb.image = ThumbnailCache.shared.image(at: firstFrame)
        lastThumb.image = ThumbnailCache.shared.image(at: lastFrame)

        if let queueIndex {
            badgeLabel.stringValue = "队列 #\(queueIndex)"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.stringValue = ""
            badgeLabel.isHidden = true
        }
    }
}

enum ThumbnailCache {
    static let shared = ThumbnailCacheBox()
}

final class ThumbnailCacheBox {
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()
    private let maxSide: CGFloat = 104

    func image(at url: URL) -> NSImage? {
        let key = url.path
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let source = NSImage(contentsOf: url) else { return nil }
        let sized = resize(source, maxSide: maxSide)
        lock.lock()
        cache[key] = sized
        lock.unlock()
        return sized
    }

    private func resize(_ image: NSImage, maxSide: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxSide / size.width, maxSide / size.height, 1)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}

// MARK: - Detail (fixed outer frame; content scrolls inside)

@MainActor
final class DetailPanel: NSView {
    var onToggleNext: ((String, String, Bool) -> Void)?
    var onRename: ((String, String) -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let documentView = FlippedClipView()
    private var clipID: String?
    private var shownClipID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView = NSClipView()
        scroll.documentView = documentView
        addSubview(scroll)

        documentView.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Document width tracks scroll viewport; height grows with content.
            documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(clip: PetClip?, all: [PetClip], threshold: Double) {
        // Keep scroll position when refreshing the same clip's link toggles.
        let keepScroll = (clip?.id != nil && clip?.id == shownClipID)
        let oldOrigin = scroll.contentView.bounds.origin

        clearStack()
        clipID = clip?.id
        shownClipID = clip?.id

        guard let clip else {
            let empty = NSTextField(wrappingLabelWithString: all.isEmpty
                ? "还没有片段。点击左上角「添加视频…」导入绿幕猫猫。"
                : "在左侧列表选择片段。可 ⌘/Shift 多选，全选后点「按所选播放」。当前共 \(all.count) 个片段。")
            empty.textColor = .secondaryLabelColor
            empty.setContentHuggingPriority(.defaultLow, for: .horizontal)
            empty.preferredMaxLayoutWidth = 420
            stack.addArrangedSubview(empty)
            return
        }

        appendClipDetail(clip: clip, all: all, threshold: threshold)
        restoreScroll(keepScroll: keepScroll, oldOrigin: oldOrigin)
    }

    func showMultiple(selected: [PetClip], queue: [String]) {
        clearStack()
        clipID = nil
        shownClipID = nil

        let title = NSTextField(labelWithString: "已选择 \(selected.count) 个片段")
        title.font = .boldSystemFont(ofSize: 16)
        stack.addArrangedSubview(title)

        let tip = NSTextField(wrappingLabelWithString: "可用「上移 / 下移」调整列表顺序，再点「按所选播放」按当前选中顺序循环播放。点「清除队列」恢复播放全部片段。")
        tip.textColor = .secondaryLabelColor
        tip.font = .systemFont(ofSize: 11)
        tip.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(tip)

        if !queue.isEmpty {
            let q = NSTextField(labelWithString: "当前播放队列 \(queue.count) 个")
            q.textColor = .systemBlue
            stack.addArrangedSubview(q)
        }

        for (i, clip) in selected.enumerated() {
            let idx = /* display index placeholder */ i
            let row = NSTextField(labelWithString: "\(i + 1). \(clip.displayTitle(indexInLibrary: idx))  ·  \(clip.metaText)")
            row.lineBreakMode = .byTruncatingTail
            row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(row)
        }
    }

    private func clearStack() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func restoreScroll(keepScroll: Bool, oldOrigin: NSPoint) {
        layoutSubtreeIfNeeded()
        if keepScroll {
            scroll.contentView.scroll(to: oldOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func appendClipDetail(clip: PetClip, all: [PetClip], threshold: Double) {
        let index = all.firstIndex(where: { $0.id == clip.id }) ?? 0
        let title = NSTextField(labelWithString: clip.displayTitle(indexInLibrary: index))
        title.font = .boldSystemFont(ofSize: 16)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(title)

        let meta = NSTextField(labelWithString: "\(clip.metaText) · \(String(format: "%.2f", clip.fps)) fps")
        meta.textColor = .secondaryLabelColor
        stack.addArrangedSubview(meta)

        let renameBtn = NSButton(title: "重命名…", target: self, action: #selector(renameCurrent))
        renameBtn.bezelStyle = .rounded
        renameBtn.identifier = NSUserInterfaceItemIdentifier(clip.id)
        stack.addArrangedSubview(renameBtn)

        let frames = NSStackView()
        frames.orientation = .horizontal
        frames.spacing = 12
        frames.setHuggingPriority(.defaultHigh, for: .vertical)
        frames.addArrangedSubview(frameThumb(url: AppPaths.frameURL(clipID: clip.id, index: 1), caption: "首帧"))
        frames.addArrangedSubview(frameThumb(url: AppPaths.frameURL(clipID: clip.id, index: max(1, clip.frameCount)), caption: "尾帧"))
        stack.addArrangedSubview(frames)

        let section = NSTextField(labelWithString: "可衔接的下一段")
        section.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(section)

        let hint = NSTextField(wrappingLabelWithString: "勾选后，在「衔接播放」模式下本段播完会进入所选片段。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(hint)

        for other in all where other.id != clip.id {
            let otherIndex = all.firstIndex(where: { $0.id == other.id }) ?? 0
            let score = TransitionMatcher.score(from: clip, to: other)
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.setContentHuggingPriority(.defaultHigh, for: .vertical)
            let box = NSButton(
                checkboxWithTitle: other.displayTitle(indexInLibrary: otherIndex),
                target: self,
                action: #selector(toggleNext(_:))
            )
            box.state = clip.nextClipIDs.contains(other.id) ? .on : .off
            box.identifier = NSUserInterfaceItemIdentifier(other.id)
            box.lineBreakMode = .byTruncatingTail
            box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let scoreLabel = NSTextField(labelWithString: String(format: "相似 %.0f%%", score * 100))
            scoreLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            scoreLabel.textColor = score >= threshold ? .systemBlue : .secondaryLabelColor
            scoreLabel.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(box)
            row.addArrangedSubview(scoreLabel)
            row.addArrangedSubview(NSView())
            stack.addArrangedSubview(row)
        }
    }

    @objc private func renameCurrent(_ sender: NSButton) {
        guard let clipID = sender.identifier?.rawValue else { return }
        let alert = NSAlert()
        alert.messageText = "重命名片段"
        alert.informativeText = "输入一个好认的名字，例如「趴着」「伸懒腰」。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onRename?(clipID, field.stringValue)
    }

    private func frameThumb(url: URL, caption: String) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .centerX
        box.spacing = 4
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(contentsOf: url)
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        imageView.layer?.cornerRadius = 8
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 140).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 140).isActive = true
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        box.addArrangedSubview(imageView)
        box.addArrangedSubview(label)
        return box
    }

    @objc private func toggleNext(_ sender: NSButton) {
        guard let clipID, let nextID = sender.identifier?.rawValue else { return }
        onToggleNext?(clipID, nextID, sender.state == .on)
    }
}

/// Top-left origin document view so growing content doesn't jump the scroll position.
private final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ProgressOverlay: NSView {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let stack = NSStackView(views: [label, bar, sub])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        bar.isIndeterminate = true
        bar.startAnimation(nil)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 260).isActive = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }

    func update(_ progress: ImportProgress) {
        if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        label.stringValue = progress.message
        sub.stringValue = progress.clipName
    }
}
