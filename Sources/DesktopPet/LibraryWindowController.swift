import AppKit
import DesktopPetCore
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class LibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private struct SettingsErrorAlert: Equatable {
        let title: String
        let message: String
    }

    private let store: LibraryStore
    private let engine: PlaylistEngine

    private let table = NSTableView()
    private let detail = DetailPanel()
    private let countLabel = NSTextField(labelWithString: "共 0 个片段")
    private let tabControl = NSSegmentedControl(
        labels: ["猫猫", "鼠标互动目标素材"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let playSelectedButton = NSButton(title: "按所选播放", target: nil, action: nil)
    private let clearQueueButton = NSButton(title: "清除队列", target: nil, action: nil)
    private let rebuildLinksButton = NSButton(title: "重算衔接", target: nil, action: nil)
    private let modePopup = NSPopUpButton()
    private let scaleSlider = NSSlider()
    private let topToggle = NSButton(checkboxWithTitle: "置顶", target: nil, action: nil)
    private let clickToggle = NSButton(checkboxWithTitle: "点击穿透", target: nil, action: nil)
    private let launchAtLoginToggle = NSButton(checkboxWithTitle: "开机启动", target: nil, action: nil)
    private let preventIdleDisplaySleepToggle = NSButton(
        checkboxWithTitle: "阻止自动锁屏与关闭屏幕",
        target: nil,
        action: nil
    )
    private let manicIdleDelayPopup = NSPopUpButton()
    private let manicScaleSlider = NSSlider()
    private let manicScaleValueLabel = NSTextField(labelWithString: "2.0×")
    private let autoLinkToggle = NSButton(checkboxWithTitle: "自动衔接", target: nil, action: nil)
    private let thresholdSlider = NSSlider()
    private let teleportToggle = NSButton(checkboxWithTitle: "随机隐现", target: nil, action: nil)
    private let teleportFrequencySlider = NSSlider()
    private let cursorNudgeToggle = NSButton(checkboxWithTitle: "鼠标附近提醒", target: nil, action: nil)
    private let editRemindersButton = NSButton(title: "编辑提醒文案…", target: nil, action: nil)
    private let progressOverlay = ProgressOverlay()
    private var isImporting = false
    private var suppressSelectionSideEffects = false
    private var selectedTab: ClipLibraryTab = .cats
    private var settingsErrorQueue: [SettingsErrorAlert] = []
    private var activeSettingsError: SettingsErrorAlert?

    private var visibleClips: [PetClip] {
        store.state.clips.filter { $0.libraryTab == selectedTab }
    }

    private var visibleClipIDs: [String] {
        visibleClips.map(\.id)
    }

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
        window.delegate = self

        buildUI()
        reload()
        NotificationCenter.default.addObserver(
            forName: .libraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload(preservingSelection: true) }
        }
        NotificationCenter.default.addObserver(
            forName: .playbackDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload(preservingSelection: true) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        detail.stopPreviews()
    }

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
        playSelectedButton.target = self
        playSelectedButton.action = #selector(playSelectedQueue)
        playSelectedButton.bezelStyle = .rounded
        clearQueueButton.target = self
        clearQueueButton.action = #selector(clearPlayQueue)
        clearQueueButton.bezelStyle = .rounded
        let deleteBtn = NSButton(title: "删除", target: self, action: #selector(deleteSelected))
        deleteBtn.bezelStyle = .rounded
        rebuildLinksButton.target = self
        rebuildLinksButton.action = #selector(rebuildLinks)
        rebuildLinksButton.bezelStyle = .rounded
        let exportBtn = NSButton(title: "导出 GIF…", target: self, action: #selector(exportSelectedClip))
        exportBtn.bezelStyle = .rounded
        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor

        row.addArrangedSubview(addBtn)
        row.addArrangedSubview(selectAllBtn)
        row.addArrangedSubview(clearSelBtn)
        row.addArrangedSubview(upBtn)
        row.addArrangedSubview(downBtn)
        row.addArrangedSubview(playSelectedButton)
        row.addArrangedSubview(clearQueueButton)
        row.addArrangedSubview(deleteBtn)
        row.addArrangedSubview(rebuildLinksButton)
        row.addArrangedSubview(exportBtn)
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

        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.selectedSegment = selectedTab.rawValue
        tabControl.target = self
        tabControl.action = #selector(libraryTabChanged)

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
        listPane.addSubview(tabControl)
        listPane.addSubview(scroll)
        NSLayoutConstraint.activate([
            listHeader.topAnchor.constraint(equalTo: listPane.topAnchor, constant: 10),
            listHeader.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 12),
            listHeader.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -8),

            tabControl.topAnchor.constraint(equalTo: listHeader.bottomAnchor, constant: 6),
            tabControl.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 10),
            tabControl.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 6),
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
                threshold: self.store.state.autoLinkThreshold,
                globalScale: self.store.state.petScale
            )
        }
        detail.onRename = { [weak self] clipID, newName in
            guard let self else { return }
            self.store.renameClip(id: clipID, to: newName)
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            self.reload(preservingSelection: true)
        }
        detail.onToggleTag = { [weak self] clipID, tag in
            guard let self else { return }
            self.store.toggleTag(clipID: clipID, tag: tag)
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        }
        detail.onToggleCursorPrey = { [weak self] clipID, enabled in
            self?.updateCursorInteractionRole(clipID: clipID, isPrey: true, enabled: enabled)
        }
        detail.onToggleCursorInteraction = { [weak self] clipID, enabled in
            self?.updateCursorInteractionRole(clipID: clipID, isPrey: false, enabled: enabled)
        }
        detail.onCursorPreyDisplaySizeChanged = { [weak self] clipID, displaySize in
            self?.store.setCursorPreyDisplaySize(clipID: clipID, displaySize: displaySize)
        }
        detail.onClipScaleChanged = { [weak self] clipID, scale in
            guard let self else { return }
            self.store.setClipScale(clipID: clipID, scale: scale)
            NotificationCenter.default.post(name: .petPresentationDidChange, object: nil)
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

        let row3 = NSStackView()
        row3.orientation = .horizontal
        row3.spacing = 12
        let freqLabel = NSTextField(labelWithString: "片段末概率")
        teleportFrequencySlider.minValue = 0
        teleportFrequencySlider.maxValue = 1
        teleportFrequencySlider.doubleValue = store.state.teleportFrequency
        teleportFrequencySlider.target = self
        teleportFrequencySlider.action = #selector(teleportSettingsChanged)
        teleportFrequencySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        teleportFrequencySlider.toolTip = "每个片段播放结束后触发隐现的概率（左低右高）"
        teleportToggle.toolTip = "开启后，在片段播完再隐现传送，避免动作做到一半消失"
        teleportToggle.target = self
        teleportToggle.action = #selector(teleportSettingsChanged)
        cursorNudgeToggle.target = self
        cursorNudgeToggle.action = #selector(teleportSettingsChanged)
        editRemindersButton.target = self
        editRemindersButton.action = #selector(editReminderMessages)
        editRemindersButton.bezelStyle = .rounded
        row3.addArrangedSubview(teleportToggle)
        row3.addArrangedSubview(freqLabel)
        row3.addArrangedSubview(teleportFrequencySlider)
        row3.addArrangedSubview(cursorNudgeToggle)
        row3.addArrangedSubview(editRemindersButton)
        row3.addArrangedSubview(NSView())

        let row4 = NSStackView()
        row4.orientation = .horizontal
        row4.spacing = 12
        preventIdleDisplaySleepToggle.target = self
        preventIdleDisplaySleepToggle.action = #selector(idlePresentationSettingsChanged)
        let idleDelayLabel = NSTextField(labelWithString: "空闲后放大")
        manicIdleDelayPopup.removeAllItems()
        let idleDelayOptions: [(title: String, seconds: TimeInterval?)] = [
            ("关闭", nil),
            ("1 分钟", 60),
            ("3 分钟", 180),
            ("5 分钟", 300),
            ("10 分钟", 600),
            ("15 分钟", 900),
            ("30 分钟", 1800)
        ]
        for option in idleDelayOptions {
            manicIdleDelayPopup.addItem(withTitle: option.title)
            manicIdleDelayPopup.lastItem?.representedObject = option.seconds.map(NSNumber.init(value:))
                ?? NSNull()
        }
        manicIdleDelayPopup.target = self
        manicIdleDelayPopup.action = #selector(idlePresentationSettingsChanged)
        let manicScaleLabel = NSTextField(labelWithString: "魔性倍率")
        manicScaleSlider.minValue = IdlePresentationPolicy.minimumManicScale
        manicScaleSlider.maxValue = IdlePresentationPolicy.maximumManicScale
        manicScaleSlider.doubleValue = store.state.manicScale
        manicScaleSlider.target = self
        manicScaleSlider.action = #selector(idlePresentationSettingsChanged)
        manicScaleSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        manicScaleValueLabel.alignment = .right
        manicScaleValueLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        row4.addArrangedSubview(preventIdleDisplaySleepToggle)
        row4.addArrangedSubview(idleDelayLabel)
        row4.addArrangedSubview(manicIdleDelayPopup)
        row4.addArrangedSubview(manicScaleLabel)
        row4.addArrangedSubview(manicScaleSlider)
        row4.addArrangedSubview(manicScaleValueLabel)
        row4.addArrangedSubview(NSView())

        let launchHint = NSTextField(wrappingLabelWithString: "「开机启动」会在登录时自动打开桌面宠物。若提示需要批准，请到 系统设置 → 通用 → 登录项 中允许。")
        launchHint.textColor = .secondaryLabelColor
        launchHint.font = .systemFont(ofSize: 11)
        launchHint.preferredMaxLayoutWidth = 820

        col.addArrangedSubview(row1)
        col.addArrangedSubview(row2)
        col.addArrangedSubview(row3)
        col.addArrangedSubview(row4)
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

            wrap.heightAnchor.constraint(equalToConstant: 184)
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

        let totalCount = store.state.clips.count
        let count = visibleClips.count
        let selectedCount = table.numberOfSelectedRows
        let activeQueue = filteredActiveQueueIDs()
        let hasActiveQueue = !store.state.activeQueue.isEmpty
        let queueCount = activeQueue.count
        let queueText = hasActiveQueue ? " · 队列 \(queueCount)" : ""
        countLabel.stringValue = "已选 \(max(selectedCount, selectedIDs.count)) / 本页 \(count) · 全部 \(totalCount)\(queueText)"
        window?.title = "桌面宠物 · 片段库（\(totalCount)）"

        suppressSelectionSideEffects = true
        table.reloadData()
        if !selectedIDs.isEmpty {
            var indices = IndexSet()
            for id in selectedIDs {
                if let idx = visibleClips.firstIndex(where: { $0.id == id }) {
                    indices.insert(idx)
                }
            }
            table.selectRowIndexes(indices, byExtendingSelection: false)
        }
        suppressSelectionSideEffects = false

        tabControl.selectedSegment = selectedTab.rawValue
        let isCatTab = selectedTab == .cats
        playSelectedButton.isEnabled = isCatTab
        clearQueueButton.isEnabled = isCatTab
        rebuildLinksButton.isEnabled = isCatTab

        modePopup.selectItem(at: PlaybackMode.allCases.firstIndex(of: store.state.playbackMode) ?? 0)
        topToggle.state = store.state.alwaysOnTop ? .on : .off
        clickToggle.state = store.state.clickThrough ? .on : .off
        launchAtLoginToggle.state = LaunchAtLogin.isEnabled ? .on : .off
        refreshIdlePresentationControls()
        autoLinkToggle.state = store.state.autoLinkEnabled ? .on : .off
        scaleSlider.doubleValue = store.state.petScale
        thresholdSlider.doubleValue = store.state.autoLinkThreshold
        thresholdSlider.isEnabled = store.state.autoLinkEnabled
        teleportToggle.state = store.state.teleportEnabled ? .on : .off
        teleportFrequencySlider.doubleValue = store.state.teleportFrequency
        cursorNudgeToggle.state = store.state.cursorNudgeEnabled ? .on : .off
        teleportFrequencySlider.isEnabled = store.state.teleportEnabled
        cursorNudgeToggle.isEnabled = store.state.teleportEnabled
        editRemindersButton.isEnabled = store.state.teleportEnabled

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
        let count = visibleClips.count
        let totalCount = store.state.clips.count
        let selectedCount = table.selectedRowIndexes.count
        let activeQueue = filteredActiveQueueIDs()
        let hasActiveQueue = !store.state.activeQueue.isEmpty
        let queueCount = activeQueue.count
        let queueText: String
        if selectedTab == .cursorTargets {
            queueText = " · 互动目标"
        } else {
            queueText = hasActiveQueue ? " · 队列 \(queueCount)" : " · 播放全部"
        }
        countLabel.stringValue = "已选 \(selectedCount) / 本页 \(count) · 全部 \(totalCount)\(queueText)"
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
        let clips = visibleClips
        return table.selectedRowIndexes.sorted().compactMap { row -> PetClip? in
            guard row >= 0, row < clips.count else { return nil }
            return clips[row]
        }
    }

    private func selectClip(id: String) {
        guard let clip = store.clip(id: id) else { return }
        if selectedTab != clip.libraryTab {
            selectedTab = clip.libraryTab
            tabControl.selectedSegment = selectedTab.rawValue
            table.reloadData()
        }
        guard let idx = visibleClips.firstIndex(where: { $0.id == id }) else { return }
        suppressSelectionSideEffects = true
        table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        table.scrollRowToVisible(idx)
        suppressSelectionSideEffects = false
        updateCountLabel()
        showSelectedDetail()
    }

    private func showSelectedDetail() {
        guard window?.isVisible == true else {
            detail.stopPreviews()
            return
        }
        let selected = selectedClips()
        if selected.count > 1 {
            detail.showMultiple(selected: selected, queue: filteredActiveQueueIDs())
        } else {
            detail.show(
                clip: selected.first,
                all: store.state.clips,
                threshold: store.state.autoLinkThreshold,
                globalScale: store.state.petScale
            )
        }
    }

    private func filteredActiveQueueIDs() -> [String] {
        guard !store.state.activeQueue.isEmpty else { return [] }
        return store.state.activeQueue.filter { id in
            store.clip(id: id)?.isCursorInteractionMaterial == false
        }
    }

    private func updateCursorInteractionRole(clipID: String, isPrey: Bool, enabled: Bool) {
        if isPrey {
            store.setCursorPreyEnabled(clipID: clipID, enabled: enabled)
        } else {
            store.setCursorInteractionEnabled(clipID: clipID, enabled: enabled)
        }

        if let clip = store.clip(id: clipID) {
            selectedTab = clip.libraryTab
            tabControl.selectedSegment = selectedTab.rawValue
        }
        // App-wide library synchronization corrects the playback target and
        // refreshes the list/detail exactly once for this role mutation.
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        reload()
        selectClip(id: clipID)
    }

    // MARK: Actions

    @objc private func libraryTabChanged() {
        guard let tab = ClipLibraryTab(rawValue: tabControl.selectedSegment) else { return }
        detail.stopPreviews()
        selectedTab = tab
        reload()
        if let firstID = visibleClips.first?.id {
            selectClip(id: firstID)
        }
    }

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
        let selectedIDs = selectedClips().map(\.id)
        guard !selectedIDs.isEmpty else { return }
        let nextIDs = store.moveVisibleClips(
            ids: visibleClipIDs,
            selectedIDs: selectedIDs,
            direction: .up
        )
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        suppressSelectionSideEffects = true
        table.reloadData()
        let next = IndexSet(nextIDs.compactMap { id in
            visibleClips.firstIndex(where: { $0.id == id })
        })
        table.selectRowIndexes(next, byExtendingSelection: false)
        if let first = next.first { table.scrollRowToVisible(first) }
        suppressSelectionSideEffects = false
        updateCountLabel()
        showSelectedDetail()
    }

    @objc private func moveSelectionDown() {
        let selectedIDs = selectedClips().map(\.id)
        guard !selectedIDs.isEmpty else { return }
        let nextIDs = store.moveVisibleClips(
            ids: visibleClipIDs,
            selectedIDs: selectedIDs,
            direction: .down
        )
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        suppressSelectionSideEffects = true
        table.reloadData()
        let next = IndexSet(nextIDs.compactMap { id in
            visibleClips.firstIndex(where: { $0.id == id })
        })
        table.selectRowIndexes(next, byExtendingSelection: false)
        if let last = next.max() { table.scrollRowToVisible(last) }
        suppressSelectionSideEffects = false
        updateCountLabel()
        showSelectedDetail()
    }

    @objc private func playSelectedQueue() {
        guard selectedTab == .cats else { return }
        let selected = selectedClips()
        guard !selected.isEmpty else { return }
        let ids = selected
            .filter { !$0.isCursorInteractionMaterial }
            .map(\.id)
        guard !ids.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "无法创建播放队列"
            alert.informativeText = "所选片段都是鼠标互动专用素材，不能参与普通播放。"
            alert.addButton(withTitle: "好")
            if let window {
                alert.beginSheetModal(for: window) { _ in }
            } else {
                alert.runModal()
            }
            return
        }
        store.setActiveQueue(ids)
        // Keep the user's current playback mode (sequential / random / graph).
        engine.playFromQueueStart()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        reload(preservingSelection: true)
    }

    @objc private func clearPlayQueue() {
        guard selectedTab == .cats else { return }
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
                    guard let previewResult = await preview.runModal(for: self.window!),
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

                    if let clip = await self.store.commitImport(
                        staging: staging,
                        settings: previewResult.settings,
                        materialType: previewResult.materialType
                    ) {
                        importedCount += 1
                        lastID = clip.id
                        self.selectedTab = clip.libraryTab
                        self.tabControl.selectedSegment = clip.libraryTab.rawValue
                        self.reload()
                        self.selectClip(id: clip.id)
                        if clip.libraryTab == .cats {
                            self.engine.playClip(id: clip.id)
                        }
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

    @objc private func exportSelectedClip() {
        guard let clip = selectedClip(), let window else { return }
        let index = store.state.clips.firstIndex(where: { $0.id == clip.id }) ?? 0

        let panel = NSSavePanel()
        let formatPopup = NSPopUpButton(frame: NSRect(x: 10, y: 4, width: 220, height: 26))
        formatPopup.addItems(withTitles: ["GIF（兼容表情包）", "APNG（无损透明）"])
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        accessory.addSubview(formatPopup)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [.gif, .png]
        panel.nameFieldStringValue = clip.displayTitle(indexInLibrary: index)

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, var url = panel.url else { return }
            let useAPNG = formatPopup.indexOfSelectedItem == 1
            let wantedExtension = useAPNG ? "png" : "gif"
            if url.pathExtension.lowercased() != wantedExtension {
                url.deletePathExtension()
                url.appendPathExtension(wantedExtension)
            }
            let ok = ClipExporter.export(clip: clip, to: url, apng: useAPNG)
            let alert = NSAlert()
            alert.messageText = ok ? "导出完成" : "导出失败"
            alert.informativeText = ok ? url.lastPathComponent : "无法写入所选位置。"
            if let window = self.window {
                alert.beginSheetModal(for: window) { _ in }
            }
        }
    }

    @objc private func rebuildLinks() {
        guard selectedTab == .cats else { return }
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

    @objc private func idlePresentationSettingsChanged() {
        let delay = (manicIdleDelayPopup.selectedItem?.representedObject as? NSNumber)?.doubleValue
        let previousLastError = store.lastError
        let saveError = store.update {
            $0.preventIdleDisplaySleep = preventIdleDisplaySleepToggle.state == .on
            $0.manicIdleDelay = delay
            $0.manicScale = IdlePresentationPolicy.clampedManicScale(manicScaleSlider.doubleValue)
        }
        manicScaleValueLabel.stringValue = String(format: "%.1f×", store.state.manicScale)
        manicScaleSlider.isEnabled = store.state.manicIdleDelay != nil
        if let saveError {
            if previousLastError == nil {
                store.consumeLastError(ifMatching: saveError)
            }
            presentIdleSettingsSaveError(saveError)
        }
        NotificationCenter.default.post(name: .idlePresentationSettingsDidChange, object: nil)
    }

    func refreshIdlePresentationControls() {
        preventIdleDisplaySleepToggle.state = store.state.preventIdleDisplaySleep ? .on : .off
        let selectedDelayIndex = manicIdleDelayPopup.itemArray.firstIndex { item in
            if let representedDelay = item.representedObject as? NSNumber,
               let storedDelay = store.state.manicIdleDelay {
                return representedDelay.doubleValue == storedDelay
            }
            return item.representedObject is NSNull && store.state.manicIdleDelay == nil
        }
        if let selectedDelayIndex {
            manicIdleDelayPopup.selectItem(at: selectedDelayIndex)
        }
        manicScaleSlider.doubleValue = store.state.manicScale
        manicScaleValueLabel.stringValue = String(format: "%.1f×", store.state.manicScale)
        manicScaleSlider.isEnabled = store.state.manicIdleDelay != nil
    }

    func presentIdleSettingsSaveError(_ message: String) {
        enqueueSettingsError(
            title: "保存设置失败",
            message: "本次运行中已生效，但未写入磁盘，重启后可能恢复旧值。\n\n\(message)"
        )
    }

    func presentIdleDisplaySleepError(_ message: String) {
        enqueueSettingsError(title: "无法阻止自动关闭屏幕", message: message)
    }

    private func enqueueSettingsError(title: String, message: String) {
        let item = SettingsErrorAlert(title: title, message: message)
        guard activeSettingsError != item, !settingsErrorQueue.contains(item) else { return }
        settingsErrorQueue.append(item)
        presentNextSettingsError()
    }

    private func presentNextSettingsError() {
        guard activeSettingsError == nil, !settingsErrorQueue.isEmpty else { return }
        let item = settingsErrorQueue.removeFirst()
        activeSettingsError = item
        let alert = NSAlert()
        alert.messageText = item.title
        alert.informativeText = item.message
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { [weak self] _ in
                self?.activeSettingsError = nil
                self?.presentNextSettingsError()
            }
        } else {
            alert.runModal()
            activeSettingsError = nil
            presentNextSettingsError()
        }
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

    @objc private func teleportSettingsChanged() {
        store.update {
            $0.teleportEnabled = teleportToggle.state == .on
            $0.teleportFrequency = teleportFrequencySlider.doubleValue
            $0.cursorNudgeEnabled = cursorNudgeToggle.state == .on
        }
        teleportFrequencySlider.isEnabled = store.state.teleportEnabled
        cursorNudgeToggle.isEnabled = store.state.teleportEnabled
        editRemindersButton.isEnabled = store.state.teleportEnabled
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    @objc private func editReminderMessages() {
        guard let parent = window else { return }
        let alert = NSAlert()
        alert.messageText = "提醒文案"
        alert.informativeText = "每行一条，保存后随机抽取。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.string = store.state.reminderMessages.joined(separator: "\n")
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let lines = textView.string
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.store.update { $0.reminderMessages = lines }
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleClips.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clips = visibleClips
        guard row >= 0, row < clips.count else { return nil }
        let clip = clips[row]
        let id = NSUserInterfaceItemIdentifier("clipCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ClipTableCellView) ?? {
            let c = ClipTableCellView()
            c.identifier = id
            return c
        }()

        let libraryIndex = store.state.clips.firstIndex(where: { $0.id == clip.id }) ?? row
        let title = clip.displayTitle(indexInLibrary: libraryIndex)
        let playing = engine.currentClipID == clip.id
        let queueIndex = filteredActiveQueueIDs().firstIndex(of: clip.id).map { $0 + 1 }
        let interactionRole: String?
        if clip.tags.contains(ClipTag.cursorPrey) {
            interactionRole = "互动目标 · 不参与普通播放"
        } else if clip.tags.contains(ClipTag.cursorInteraction) {
            interactionRole = "互动猫片段 · 不参与普通播放"
        } else {
            interactionRole = nil
        }
        cell.configure(
            title: title,
            meta: clip.metaText,
            playCount: clip.playCountText,
            firstFrame: AppPaths.frameURL(clipID: clip.id, index: 1),
            lastFrame: AppPaths.frameURL(clipID: clip.id, index: max(1, clip.frameCount)),
            queueIndex: queueIndex,
            interactionRole: interactionRole,
            isPlaying: playing
        )
        cell.toolTip = "\(title)\n导入：\(clip.importedAtText)\n\(clip.frameCount) 帧 · \(String(format: "%.1f", clip.duration)) 秒\n播放 \(clip.playCount) 次"
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
    private let playCountLabel = NSTextField(labelWithString: "")

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
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(metaLabel)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .systemBlue
        badgeLabel.isHidden = true
        addSubview(badgeLabel)

        playCountLabel.translatesAutoresizingMaskIntoConstraints = false
        playCountLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        playCountLabel.textColor = .secondaryLabelColor
        playCountLabel.alignment = .right
        playCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        playCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(playCountLabel)

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

            playCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            playCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            playCountLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: lastThumb.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: playCountLabel.leadingAnchor, constant: -8),
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
        playCount: String,
        firstFrame: URL,
        lastFrame: URL,
        queueIndex: Int?,
        interactionRole: String?,
        isPlaying: Bool
    ) {
        titleLabel.stringValue = title + (isPlaying ? "  ▶" : "")
        metaLabel.stringValue = meta
        playCountLabel.stringValue = playCount
        firstThumb.image = ThumbnailCache.shared.image(at: firstFrame)
        lastThumb.image = ThumbnailCache.shared.image(at: lastFrame)

        let badges = [
            queueIndex.map { "队列 #\($0)" },
            interactionRole
        ].compactMap { $0 }
        if !badges.isEmpty {
            badgeLabel.stringValue = badges.joined(separator: " · ")
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
    var onToggleTag: ((String, String) -> Void)?
    var onToggleCursorPrey: ((String, Bool) -> Void)?
    var onToggleCursorInteraction: ((String, Bool) -> Void)?
    var onCursorPreyDisplaySizeChanged: ((String, Double) -> Void)?
    var onClipScaleChanged: ((String, Double) -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let documentView = FlippedClipView()
    private let preview = ClipPreviewPlayer()
    private let cursorPreyPreview = CursorPreyPreview()
    private var clipID: String?
    private var shownClipID: String?
    private var globalScale = 1.0
    private weak var clipScaleSlider: NSSlider?
    private weak var clipScaleValueLabel: NSTextField?
    private weak var clipEffectiveScaleLabel: NSTextField?

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

    func show(clip: PetClip?, all: [PetClip], threshold: Double, globalScale: Double) {
        // Keep scroll position when refreshing the same clip's link toggles.
        let keepScroll = (clip?.id != nil && clip?.id == shownClipID)
        let oldOrigin = scroll.contentView.bounds.origin

        clearStack()
        clipID = clip?.id
        shownClipID = clip?.id
        self.globalScale = globalScale

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

    func stopPreviews() {
        preview.stop()
        cursorPreyPreview.stop()
    }

    private func clearStack() {
        stopPreviews()
        clipScaleSlider = nil
        clipScaleValueLabel = nil
        clipEffectiveScaleLabel = nil
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

        let pettingToggle = NSButton(
            checkboxWithTitle: "被摸反应片段（点按猫咪时播放）",
            target: self,
            action: #selector(togglePettingTag(_:))
        )
        pettingToggle.state = clip.tags.contains(ClipTag.petting) ? .on : .off
        pettingToggle.identifier = NSUserInterfaceItemIdentifier(clip.id)
        stack.addArrangedSubview(pettingToggle)

        let cursorPreyToggle = NSButton(
            checkboxWithTitle: "鼠标互动目标素材",
            target: self,
            action: #selector(toggleCursorPrey(_:))
        )
        cursorPreyToggle.state = clip.tags.contains(ClipTag.cursorPrey) ? .on : .off
        cursorPreyToggle.identifier = NSUserInterfaceItemIdentifier(clip.id)
        stack.addArrangedSubview(cursorPreyToggle)

        let cursorInteractionToggle = NSButton(
            checkboxWithTitle: "鼠标互动猫片段",
            target: self,
            action: #selector(toggleCursorInteraction(_:))
        )
        cursorInteractionToggle.state = clip.tags.contains(ClipTag.cursorInteraction) ? .on : .off
        cursorInteractionToggle.identifier = NSUserInterfaceItemIdentifier(clip.id)
        stack.addArrangedSubview(cursorInteractionToggle)

        let cursorInteractionHint = NSTextField(wrappingLabelWithString: "两类鼠标互动专用素材都不会参与普通播放、播放队列或自动衔接；两种角色互斥。")
        cursorInteractionHint.textColor = .secondaryLabelColor
        cursorInteractionHint.font = .systemFont(ofSize: 11)
        cursorInteractionHint.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(cursorInteractionHint)

        if clip.tags.contains(ClipTag.cursorPrey) {
            appendCursorPreyEditor(clip: clip)
        } else {
            appendClipScaleEditor(clip: clip)
        }

        // Ordinary clips retain the existing full-motion preview. Prey clips
        // use the focused point-size preview added above instead.
        if !clip.tags.contains(ClipTag.cursorPrey) {
            stack.addArrangedSubview(preview)
            preview.load(clip: clip)
        }

        let frames = NSStackView()
        frames.orientation = .horizontal
        frames.spacing = 12
        frames.setHuggingPriority(.defaultHigh, for: .vertical)
        frames.addArrangedSubview(frameThumb(url: AppPaths.frameURL(clipID: clip.id, index: 1), caption: "首帧"))
        frames.addArrangedSubview(frameThumb(url: AppPaths.frameURL(clipID: clip.id, index: max(1, clip.frameCount)), caption: "尾帧"))
        stack.addArrangedSubview(frames)

        guard !clip.isCursorInteractionMaterial else { return }

        let section = NSTextField(labelWithString: "可衔接的下一段")
        section.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(section)

        let hint = NSTextField(wrappingLabelWithString: "勾选后，在「衔接播放」模式下本段播完会进入所选片段。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(hint)

        for other in all where other.id != clip.id && !other.isCursorInteractionMaterial {
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

    private func appendCursorPreyEditor(clip: PetClip) {
        let settings = clip.cursorPreySettings ?? CursorPreySettings()
        let section = NSTextField(labelWithString: "互动目标大小")
        section.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(section)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let slider = NSSlider()
        slider.minValue = CursorInteractionPolicy.minimumPreyDisplaySize
        slider.maxValue = CursorInteractionPolicy.maximumPreyDisplaySize
        slider.doubleValue = settings.displaySize
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(cursorPreySizeChanged(_:))
        slider.identifier = NSUserInterfaceItemIdentifier(clip.id)
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let sizeLabel = NSTextField(labelWithString: Self.preySizeText(settings.displaySize))
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.identifier = NSUserInterfaceItemIdentifier("cursorPreySizeLabel")

        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetCursorPreySize(_:)))
        resetButton.bezelStyle = .rounded
        resetButton.identifier = NSUserInterfaceItemIdentifier(clip.id)

        row.addArrangedSubview(slider)
        row.addArrangedSubview(sizeLabel)
        row.addArrangedSubview(resetButton)
        stack.addArrangedSubview(row)

        stack.addArrangedSubview(cursorPreyPreview)
        cursorPreyPreview.load(clip: clip, displaySize: settings.displaySize)
    }

    private func appendClipScaleEditor(clip: PetClip) {
        let section = NSTextField(labelWithString: "猫猫片段大小")
        section.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(section)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let slider = NSSlider()
        slider.minValue = PetClipPresentationPolicy.minimumClipScale
        slider.maxValue = PetClipPresentationPolicy.maximumClipScale
        slider.doubleValue = clip.clipScale
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(clipScaleChanged(_:))
        slider.identifier = NSUserInterfaceItemIdentifier(clip.id)
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let valueLabel = NSTextField(labelWithString: Self.clipScaleText(clip.clipScale))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetClipScale(_:)))
        resetButton.bezelStyle = .rounded
        resetButton.identifier = NSUserInterfaceItemIdentifier(clip.id)

        row.addArrangedSubview(slider)
        row.addArrangedSubview(valueLabel)
        row.addArrangedSubview(resetButton)
        stack.addArrangedSubview(row)

        let effectiveLabel = NSTextField(labelWithString: PetClipPresentationPolicy.scaleSummary(
            clipScale: clip.clipScale,
            globalScale: globalScale
        ))
        effectiveLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        effectiveLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(effectiveLabel)

        clipScaleSlider = slider
        clipScaleValueLabel = valueLabel
        clipEffectiveScaleLabel = effectiveLabel
    }

    private static func clipScaleText(_ scale: Double) -> String {
        String(format: "%.2f×", PetClipPresentationPolicy.clampedClipScale(scale))
    }

    private static func preySizeText(_ displaySize: Double) -> String {
        "\(Int(displaySize.rounded())) pt"
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

    @objc private func togglePettingTag(_ sender: NSButton) {
        guard let clipID = sender.identifier?.rawValue else { return }
        onToggleTag?(clipID, ClipTag.petting)
    }

    @objc private func toggleCursorPrey(_ sender: NSButton) {
        guard let clipID = sender.identifier?.rawValue else { return }
        onToggleCursorPrey?(clipID, sender.state == .on)
    }

    @objc private func toggleCursorInteraction(_ sender: NSButton) {
        guard let clipID = sender.identifier?.rawValue else { return }
        onToggleCursorInteraction?(clipID, sender.state == .on)
    }

    @objc private func clipScaleChanged(_ sender: NSSlider) {
        guard let clipID = sender.identifier?.rawValue else { return }
        let scale = PetClipPresentationPolicy.clampedClipScale(sender.doubleValue)
        updateClipScaleEditor(scale)
        onClipScaleChanged?(clipID, scale)
    }

    @objc private func resetClipScale(_ sender: NSButton) {
        guard let clipID = sender.identifier?.rawValue else { return }
        let scale = PetClipPresentationPolicy.defaultClipScale
        updateClipScaleEditor(scale)
        onClipScaleChanged?(clipID, scale)
    }

    private func updateClipScaleEditor(_ scale: Double) {
        let value = PetClipPresentationPolicy.clampedClipScale(scale)
        clipScaleSlider?.doubleValue = value
        clipScaleValueLabel?.stringValue = Self.clipScaleText(value)
        clipEffectiveScaleLabel?.stringValue = PetClipPresentationPolicy.scaleSummary(
            clipScale: value,
            globalScale: globalScale
        )
    }

    @objc private func cursorPreySizeChanged(_ sender: NSSlider) {
        guard let clipID = sender.identifier?.rawValue else { return }
        let displaySize = CursorInteractionPolicy.clampedPreyDisplaySize(sender.doubleValue)
        sender.doubleValue = displaySize
        updateCursorPreySizeEditor(displaySize)
        onCursorPreyDisplaySizeChanged?(clipID, displaySize)
    }

    @objc private func resetCursorPreySize(_ sender: NSButton) {
        guard let clipID = sender.identifier?.rawValue else { return }
        let displaySize = CursorInteractionPolicy.defaultPreyDisplaySize
        updateCursorPreySizeEditor(displaySize)
        onCursorPreyDisplaySizeChanged?(clipID, displaySize)
    }

    private func updateCursorPreySizeEditor(_ displaySize: Double) {
        let value = CursorInteractionPolicy.clampedPreyDisplaySize(displaySize)
        stack.arrangedSubviews.compactMap { $0 as? NSStackView }.forEach { row in
            row.arrangedSubviews.compactMap { $0 as? NSSlider }
                .first(where: { $0.identifier?.rawValue == clipID })?
                .doubleValue = value
            row.arrangedSubviews.compactMap { $0 as? NSTextField }
                .first(where: { $0.identifier?.rawValue == "cursorPreySizeLabel" })?
                .stringValue = Self.preySizeText(value)
        }
        cursorPreyPreview.setDisplaySize(value)
    }
}

// MARK: - Cursor-prey size preview

/// Shows the target at the exact point size used by the cursor overlay while
/// keeping a stable checkerboard canvas around it for alpha inspection.
@MainActor
private final class CursorPreyPreview: NSView {
    private let canvas = NSView()
    private let imageView = NSImageView()
    private var imageWidthConstraint: NSLayoutConstraint!
    private var imageHeightConstraint: NSLayoutConstraint!
    private var timer: Timer?
    private var clipID: String?
    private var frameCount = 1
    private var fps = 24.0
    private var currentFrame = 1
    private var aspectRatio = 1.0
    private var cache: [Int: NSImage] = [:]
    private var cacheOrder: [Int] = []
    private let cacheLimit = 40

    private static let checkerboard: NSColor = {
        let side: CGFloat = 16
        let half = side / 2
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: half, height: half).fill()
        NSRect(x: half, y: half, width: half, height: half).fill()
        image.unlockFocus()
        return NSColor(patternImage: image)
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = Self.checkerboard.cgColor
        canvas.layer?.cornerRadius = 8
        canvas.layer?.masksToBounds = true
        canvas.layer?.borderWidth = 0.5
        canvas.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(canvas)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleAxesIndependently
        canvas.addSubview(imageView)
        imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: CursorInteractionPolicy.defaultPreyDisplaySize)
        imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: CursorInteractionPolicy.defaultPreyDisplaySize)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 260),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.widthAnchor.constraint(equalToConstant: 240),
            canvas.heightAnchor.constraint(equalToConstant: 180),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            imageWidthConstraint,
            imageHeightConstraint
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    func load(clip: PetClip, displaySize: Double) {
        stop()
        clipID = clip.id
        frameCount = max(1, clip.frameCount)
        fps = clip.fps > 0 ? clip.fps : 24
        aspectRatio = clip.displayWidth > 0 && clip.displayHeight > 0
            ? Double(clip.displayWidth) / Double(clip.displayHeight)
            : 1
        cache.removeAll()
        cacheOrder.removeAll()
        currentFrame = 1
        setDisplaySize(displaySize)
        showFrame(1)
        startPlaying()
    }

    func setDisplaySize(_ displaySize: Double) {
        let longestSide = CGFloat(CursorInteractionPolicy.clampedPreyDisplaySize(displaySize))
        let safeAspectRatio = max(aspectRatio, 0.0001)
        if safeAspectRatio >= 1 {
            imageWidthConstraint.constant = longestSide
            imageHeightConstraint.constant = longestSide / safeAspectRatio
        } else {
            imageWidthConstraint.constant = longestSide * safeAspectRatio
            imageHeightConstraint.constant = longestSide
        }
        layoutSubtreeIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startPlaying() {
        guard frameCount > 1 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        showFrame(currentFrame % frameCount + 1)
    }

    private func showFrame(_ index: Int) {
        currentFrame = index
        imageView.image = frameImage(at: index)
    }

    private func frameImage(at index: Int) -> NSImage? {
        guard let clipID else { return nil }
        if let image = cache[index] { return image }
        guard let image = NSImage(contentsOf: AppPaths.frameURL(clipID: clipID, index: index)) else {
            return nil
        }
        cache[index] = image
        cacheOrder.append(index)
        if cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return image
    }
}

// MARK: - Full-clip preview player

/// Loops a clip's keyed transparent PNG frame sequence at its native fps,
/// with play/pause, a scrubber, and a frame counter — so the detail pane
/// previews the whole motion instead of only first/last frames.
@MainActor
final class ClipPreviewPlayer: NSView {
    private let imageView = NSImageView()
    private let playButton = NSButton()
    private let slider = NSSlider()
    private let frameLabel = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var clipID: String?
    private var frameCount = 1
    private var fps: Double = 24
    private var currentFrame = 1
    private var isPlayingPreview = false
    private var cache: [Int: NSImage] = [:]
    private var cacheOrder: [Int] = []
    private let cacheLimit = 40

    /// Checkerboard pattern so the alpha channel reads clearly.
    private static let checkerboard: NSColor = {
        let side: CGFloat = 16
        let half = side / 2
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: half, height: half).fill()
        NSRect(x: half, y: half, width: half, height: half).fill()
        image.unlockFocus()
        return NSColor(patternImage: image)
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = Self.checkerboard.cgColor
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 0.5
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(imageView)

        playButton.bezelStyle = .rounded
        playButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "暂停")
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playButton)

        slider.minValue = 1
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)

        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        frameLabel.textColor = .secondaryLabelColor
        frameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(frameLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 260),

            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 240),
            imageView.heightAnchor.constraint(equalToConstant: 240),

            playButton.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            playButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 34),

            slider.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 8),
            slider.widthAnchor.constraint(equalToConstant: 126),

            frameLabel.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            frameLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            frameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            bottomAnchor.constraint(equalTo: playButton.bottomAnchor)
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window (detail cleared, library closed) stops playback.
        if window == nil { stop() }
    }

    func load(clip: PetClip) {
        stop()
        clipID = clip.id
        frameCount = max(1, clip.frameCount)
        fps = clip.fps > 0 ? clip.fps : 24
        cache.removeAll()
        cacheOrder.removeAll()
        slider.minValue = 1
        slider.maxValue = Double(frameCount)
        showFrame(1)
        startPlaying()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isPlayingPreview = false
        updatePlayButton()
    }

    private func startPlaying() {
        timer?.invalidate()
        timer = nil
        guard frameCount > 1 else {
            isPlayingPreview = false
            updatePlayButton()
            return
        }
        isPlayingPreview = true
        updatePlayButton()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        showFrame(currentFrame % frameCount + 1)
    }

    private func showFrame(_ index: Int) {
        currentFrame = index
        imageView.image = frameImage(at: index)
        slider.doubleValue = Double(index)
        frameLabel.stringValue = "\(index) / \(frameCount) 帧"
    }

    private func frameImage(at index: Int) -> NSImage? {
        guard let clipID else { return nil }
        if let hit = cache[index] { return hit }
        let url = AppPaths.frameURL(clipID: clipID, index: index)
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[index] = image
        cacheOrder.append(index)
        if cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return image
    }

    private func updatePlayButton() {
        let symbol = isPlayingPreview ? "pause.fill" : "play.fill"
        let label = isPlayingPreview ? "暂停" : "播放"
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }

    @objc private func togglePlay() {
        if isPlayingPreview {
            stop()
        } else {
            startPlaying()
        }
    }

    @objc private func sliderMoved() {
        // Scrubbing pauses playback; hit play to resume from here.
        if isPlayingPreview { stop() }
        let index = max(1, min(frameCount, Int(slider.doubleValue.rounded())))
        showFrame(index)
    }
}

/// Top-left origin document view so growing content doesn't jump the scroll position.
private final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Clip export (GIF / APNG stickers)

enum ClipExporter {
    /// Assemble the keyed frame sequence into a looping GIF or APNG.
    /// Caps at ~60 frames (striding) and 480px on the long side.
    static func export(clip: PetClip, to url: URL, apng: Bool) -> Bool {
        let maxFrames = 60
        let step = max(1, Int(ceil(Double(clip.frameCount) / Double(maxFrames))))
        var indices: [Int] = []
        var cursor = 1
        while cursor <= clip.frameCount {
            indices.append(cursor)
            cursor += step
        }
        guard !indices.isEmpty else { return false }
        let delay = Double(step) / max(1.0, clip.fps)

        let typeIdentifier = (apng ? UTType.png : UTType.gif).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, typeIdentifier, indices.count, nil
        ) else { return false }

        if apng {
            let fileProperties = [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]
            ] as CFDictionary
            CGImageDestinationSetProperties(destination, fileProperties)
        } else {
            let fileProperties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary
            CGImageDestinationSetProperties(destination, fileProperties)
        }

        for index in indices {
            let frameURL = AppPaths.frameURL(clipID: clip.id, index: index)
            guard let image = NSImage(contentsOf: frameURL) else { continue }
            var proposedRect = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                continue
            }
            let scaled = downscale(cg, maxSide: 480)
            let frameProperties: CFDictionary
            if apng {
                frameProperties = [
                    kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]
                ] as CFDictionary
            } else {
                frameProperties = [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
                ] as CFDictionary
            }
            CGImageDestinationAddImage(destination, scaled, frameProperties)
        }
        return CGImageDestinationFinalize(destination)
    }

    private static func downscale(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxSide / max(width, height))
        guard scale < 1 else { return image }
        let newWidth = Int(width * scale)
        let newHeight = Int(height * scale)
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }
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
