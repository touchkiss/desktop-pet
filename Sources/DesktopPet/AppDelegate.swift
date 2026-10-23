import AppKit
import Carbon.HIToolbox
import DesktopPetCore

@main
enum DesktopPetMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = LibraryStore()
    let engine = PlaylistEngine()

    private let mediaMigration = ClipMediaMigrationController()
    private var migrationMenuItem: NSMenuItem?
    private var statusItem: NSStatusItem?
    private var petWindow: PetWindowController?
    private var teleportController: TeleportController?
    private var libraryWindow: LibraryWindowController?
    private var hotKey: GlobalHotKey?
    private let pomodoro = PomodoroController()
    private let downloadsWatcher = DownloadsWatcher()
    private var sniffMenuItem: NSMenuItem?
    private var importProgressTimer: Timer?
    private var lastRendered: (String?, Int) = (nil, -1)
    private var wasImporting = false
    private let idleDisplaySleepController = IOKitIdleDisplaySleepController()
    private var idlePresentationTimer: Timer?
    private var currentIdlePresentationPhase: IdlePresentationPhase = .normal
    private var isRecoveringDisplaySleepSetting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.attach(store: store)

        let pet = PetWindowController(store: store, engine: engine)
        petWindow = pet
        engine.playbackTimeProvider = { [weak pet] id in pet?.videoPlaybackTime(for: id) }
        pet.showWindow(nil)

        let teleport = TeleportController(store: store, pet: pet, engine: engine)
        teleportController = teleport
        teleport.start()

        // —— Interactions & companions ——
        pet.onPetTapped = { [weak self] in
            self?.handlePetTapped()
        }
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_C),
            carbonModifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in
            self?.teleportController?.summonToCursor()
        }
        pomodoro.onPhaseEnd = { [weak self] _, message in
            self?.teleportController?.summonToCursor(message: message)
        }
        downloadsWatcher.onNewFile = { [weak self] name in
            self?.teleportController?.summonToCursor(message: "有新文件：\(name)")
        }
        if UserDefaults.standard.object(forKey: "sniffDownloads") == nil {
            UserDefaults.standard.set(true, forKey: "sniffDownloads")
        }
        if UserDefaults.standard.bool(forKey: "sniffDownloads") {
            downloadsWatcher.start()
        }

        setupStatusItem()
        if !UserDefaults.standard.bool(forKey: "minimizeWindowAfterLaunch") {
            openLibrary()
        }
        synchronizeIdleDisplaySleep()
        updateIdlePresentation()

        idlePresentationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateIdlePresentation()
            }
        }
        if let idlePresentationTimer {
            RunLoop.main.add(idlePresentationTimer, forMode: .common)
        }

        engine.onFrameChanged = { [weak self] in
            // Keep rendering outside engine mutations: a failed frame can change playback.
            Task { @MainActor [weak self] in
                self?.syncPetFrame()
            }
        }
        syncPetFrame()

        importProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollImportProgress()
            }
        }
        importProgressTimer?.tolerance = 0.05
        if let importProgressTimer {
            RunLoop.main.add(importProgressTimer, forMode: .common)
        }

        NotificationCenter.default.addObserver(
            forName: .libraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleLibraryChange()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .idlePresentationSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleIdlePresentationSettingsChange()
            }
        }

        mediaMigration.onProgress = { [weak self] message in
            self?.migrationMenuItem?.title = message
        }
        mediaMigration.onClipConverted = { [weak self] id in
            guard let self else { return }
            if self.engine.currentClipID == id { self.petWindow?.reloadVideo() }
        }
        mediaMigration.start(clips: store.state.clips)

        if store.state.clips.isEmpty {
            bootstrapSampleIfNeeded()
        } else if let id = store.state.playableClips.first?.id {
            engine.playClip(id: id)
        }
    }

    private func bootstrapSampleIfNeeded() {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("9bcc0714258818f2cbe70b24896a9fa7_raw.mp4"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("9bcc0714258818f2cbe70b24896a9fa7_raw.mp4")
        ]
        guard let sample = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return
        }
        Task {
            do {
                let staging = try store.prepareStaging(from: sample, displayName: "示例猫猫")
                _ = await store.commitImport(staging: staging, settings: .default)
            } catch {
                store.lastError = error.localizedDescription
            }
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            if let id = store.state.clips.first?.id {
                engine.playClip(id: id)
            }
        }
    }

    private func pollImportProgress() {
        let importing = store.importProgress != nil
        if importing {
            libraryWindow?.tickImportProgress()
        } else if wasImporting {
            libraryWindow?.reload()
        }
        wasImporting = importing
    }

    private func handleLibraryChange() {
        teleportController?.syncFromStore()
        petWindow?.applyWindowFlags()
        if engine.currentClipID == nil, let id = store.state.playableClips.first?.id {
            engine.playClip(id: id)
        } else if let id = engine.currentClipID, store.clip(id: id) == nil {
            if engine.isPlayingOneShot {
                engine.cancelOneShotAndRestore(reason: .sourceInvalidated)
            } else if let next = store.state.playableClips.first?.id {
                engine.playClip(id: next)
            } else {
                engine.stop()
                petWindow?.refreshFrame()
            }
        } else if let id = engine.currentClipID,
                  let clip = store.clip(id: id),
                  engine.isPlayingOneShot,
                  !clip.tags.contains(ClipTag.cursorInteraction) {
            engine.cancelOneShotAndRestore(reason: .sourceInvalidated)
        } else if let id = engine.currentClipID,
                  store.clip(id: id)?.isCursorInteractionMaterial == true,
                  !engine.isPlayingOneShot {
            if let next = store.state.playableClips.first?.id {
                engine.playClip(id: next)
            } else {
                engine.stop()
                petWindow?.refreshFrame()
            }
        } else {
            engine.restartTimer()
            petWindow?.refreshFrame()
        }
    }

    private func handleIdlePresentationSettingsChange() {
        synchronizeIdleDisplaySleep()
        updateIdlePresentation(forceRefresh: true)
    }

    private func synchronizeIdleDisplaySleep() {
        guard !isRecoveringDisplaySleepSetting else { return }
        do {
            try idleDisplaySleepController.setEnabled(store.state.preventIdleDisplaySleep)
        } catch {
            isRecoveringDisplaySleepSetting = true
            let previousLastError = store.lastError
            let saveError = store.update { $0.preventIdleDisplaySleep = false }
            isRecoveringDisplaySleepSetting = false
            if let saveError {
                if previousLastError == nil {
                    store.consumeLastError(ifMatching: saveError)
                }
                libraryWindow?.presentIdleSettingsSaveError(saveError)
            }
            libraryWindow?.refreshIdlePresentationControls()
            libraryWindow?.presentIdleDisplaySleepError(error.localizedDescription)
        }
    }

    private func updateIdlePresentation(forceRefresh: Bool = false) {
        let rawIdle = HIDIdleTimeQuery.secondsSinceAnyInput { eventTypeRawValue in
            guard let eventType = CGEventType(rawValue: eventTypeRawValue) else { return 0 }
            return CGEventSource.secondsSinceLastEventType(
                .hidSystemState,
                eventType: eventType
            )
        }
        let phase = IdlePresentationPolicy.phase(
            idleSeconds: rawIdle,
            delay: store.state.manicIdleDelay
        )
        guard phase != currentIdlePresentationPhase else {
            if forceRefresh {
                petWindow?.refreshFrame()
            }
            return
        }
        currentIdlePresentationPhase = phase
        petWindow?.setIdlePresentationPhase(phase)
    }

    private func syncPetFrame() {
        let key = (engine.currentClipID, engine.currentFrameIndex)
        guard key != lastRendered else { return }
        lastRendered = key
        petWindow?.refreshFrame()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Desktop Pet")
                ?? NSImage(systemSymbolName: "hare.fill", accessibilityDescription: "Desktop Pet")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开片段库", action: #selector(openLibrary), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "显示/隐藏宠物", action: #selector(togglePet), keyEquivalent: "p"))

        // Effect tuning: trigger any teleport style on demand, no dice.
        let previewMenu = NSMenu()
        let styleItems: [(String, TeleportEffectStyle)] = [
            ("化灰", .particles),
            ("老电视", .beam),
            ("闪现", .blink),
            ("像素块", .pixel),
            ("拉丝", .smear),
            ("扫描线", .scanline),
            ("墨滴", .ink),
            ("显影", .develop),
            ("像素洪流", .swarm)
        ]
        for (title, style) in styleItems {
            let styleItem = NSMenuItem(title: title, action: #selector(previewTeleport(_:)), keyEquivalent: "")
            styleItem.target = self
            styleItem.representedObject = style.rawValue
            previewMenu.addItem(styleItem)
        }
        let randomItem = NSMenuItem(title: "随机风格", action: #selector(previewTeleport(_:)), keyEquivalent: "t")
        randomItem.target = self
        previewMenu.addItem(randomItem)
        let previewRoot = NSMenuItem(title: "预览隐现特效", action: nil, keyEquivalent: "")
        menu.addItem(previewRoot)
        menu.setSubmenu(previewMenu, for: previewRoot)

        let summonItem = NSMenuItem(title: "召唤到光标（⌃⌥C）", action: #selector(summonPet), keyEquivalent: "")
        summonItem.target = self
        menu.addItem(summonItem)

        let pomodoroMenu = NSMenu()
        let startPomo = NSMenuItem(title: "开始（专注 25 分钟 + 休息 5 分钟）", action: #selector(startPomodoro), keyEquivalent: "")
        startPomo.target = self
        pomodoroMenu.addItem(startPomo)
        let stopPomo = NSMenuItem(title: "停止", action: #selector(stopPomodoro), keyEquivalent: "")
        stopPomo.target = self
        pomodoroMenu.addItem(stopPomo)
        let pomodoroRoot = NSMenuItem(title: "番茄钟", action: nil, keyEquivalent: "")
        menu.addItem(pomodoroRoot)
        menu.setSubmenu(pomodoroMenu, for: pomodoroRoot)

        let sniff = NSMenuItem(title: "下载嗅探", action: #selector(toggleSniffer), keyEquivalent: "")
        sniff.target = self
        sniff.state = UserDefaults.standard.bool(forKey: "sniffDownloads") ? .on : .off
        menu.addItem(sniff)
        sniffMenuItem = sniff

        menu.addItem(.separator())
        let migration = NSMenuItem(title: "升级旧片段为透明视频", action: #selector(retryMediaMigration), keyEquivalent: "")
        migration.target = self
        migrationMenuItem = migration
        menu.addItem(migration)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func previewTeleport(_ sender: NSMenuItem) {
        let style = (sender.representedObject as? String)
            .flatMap { TeleportEffectStyle(rawValue: $0) }
        teleportController?.previewTrip(style: style)
    }

    private func handlePetTapped() {
        let candidates = store.state.clips.filter {
            $0.tags.contains(ClipTag.petting) && !$0.isCursorInteractionMaterial
        }
        if let clip = candidates.randomElement() {
            engine.playClip(id: clip.id)
        }
        teleportController?.showBubble(candidates.isEmpty ? "喵？" : "咕噜咕噜～")
    }

    @objc private func summonPet() {
        teleportController?.summonToCursor()
    }

    @objc private func startPomodoro() {
        pomodoro.start()
        teleportController?.showBubble("番茄钟开始，专注 25 分钟")
    }

    @objc private func stopPomodoro() {
        guard pomodoro.isRunning else { return }
        pomodoro.stop()
        teleportController?.showBubble("番茄钟已停止")
    }

    @objc private func toggleSniffer() {
        let enabled = !UserDefaults.standard.bool(forKey: "sniffDownloads")
        UserDefaults.standard.set(enabled, forKey: "sniffDownloads")
        sniffMenuItem?.state = enabled ? .on : .off
        if enabled {
            downloadsWatcher.start()
        } else {
            downloadsWatcher.stop()
        }
    }

    @objc func openLibrary() {
        if let libraryWindow {
            libraryWindow.showWindow(nil)
            libraryWindow.reload()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = LibraryWindowController(store: store, engine: engine)
        libraryWindow = wc
        wc.showWindow(nil)
        wc.reload()
        wc.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func togglePet() {
        guard let window = petWindow?.window else { return }
        if window.isVisible {
            window.orderOut(nil)
            teleportController?.setPetVisible(false)
        } else {
            window.orderFront(nil)
            teleportController?.setPetVisible(true)
        }
    }

    @objc private func retryMediaMigration() {
        mediaMigration.start(clips: store.state.clips)
    }

    @objc func quit() {
        teleportController?.stop()
        do {
            try idleDisplaySleepController.setEnabled(false)
        } catch {
            NSLog("DesktopPet: %@", error.localizedDescription)
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        idlePresentationTimer?.invalidate()
        idlePresentationTimer = nil
        do {
            try idleDisplaySleepController.setEnabled(false)
        } catch {
            NSLog("DesktopPet: %@", error.localizedDescription)
        }
    }
}
