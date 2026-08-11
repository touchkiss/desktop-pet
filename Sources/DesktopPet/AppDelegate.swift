import AppKit

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

    private var statusItem: NSStatusItem?
    private var petWindow: PetWindowController?
    private var teleportController: TeleportController?
    private var libraryWindow: LibraryWindowController?
    private var syncTimer: Timer?
    private var lastRendered: (String?, Int) = (nil, -1)
    private var wasImporting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.attach(store: store)

        let pet = PetWindowController(store: store, engine: engine)
        petWindow = pet
        pet.showWindow(nil)

        let teleport = TeleportController(store: store, pet: pet, engine: engine)
        teleportController = teleport
        teleport.start()

        setupStatusItem()
        openLibrary()

        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncPetFrame()
                self?.pollImportProgress()
            }
        }
        if let syncTimer {
            RunLoop.main.add(syncTimer, forMode: .common)
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
        libraryWindow?.reload(preservingSelection: true)
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc func openLibrary() {
        if let libraryWindow {
            libraryWindow.reload()
            libraryWindow.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = LibraryWindowController(store: store, engine: engine)
        libraryWindow = wc
        wc.showWindow(nil)
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

    @objc func quit() {
        teleportController?.stop()
        NSApp.terminate(nil)
    }
}
