import Foundation
import AppKit

enum AppPaths {
    static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = base.appendingPathComponent("DesktopPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static var libraryURL: URL {
        supportRoot.appendingPathComponent("library.json")
    }

    static var clipsRoot: URL {
        let url = supportRoot.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func clipDirectory(id: String) -> URL {
        let url = clipsRoot.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func framesDirectory(id: String) -> URL {
        let url = clipDirectory(id: id).appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func frameURL(clipID: String, index: Int) -> URL {
        framesDirectory(id: clipID).appendingPathComponent(String(format: "%05d.png", index))
    }
}

enum FFmpegLocator {
    static func resolve() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["ffmpeg"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}

final class LibraryStore {
    private(set) var state: LibraryState
    var importProgress: ImportProgress?
    var lastError: String?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        if let data = try? Data(contentsOf: AppPaths.libraryURL),
           let loaded = try? decoder.decode(LibraryState.self, from: data) {
            state = loaded
        } else {
            state = .empty
        }
        migrateHashNamesIfNeeded()
    }

    /// Replace hash-like clip names with "猫猫 N" once, so the list is readable.
    private func migrateHashNamesIfNeeded() {
        var maxIndex = 0
        for clip in state.clips {
            if clip.name.hasPrefix("猫猫 "),
               let n = Int(clip.name.dropFirst(3).trimmingCharacters(in: .whitespaces)) {
                maxIndex = max(maxIndex, n)
            }
        }
        var nextIndex = maxIndex + 1
        var changed = false
        for i in state.clips.indices where state.clips[i].hasHashLikeName {
            state.clips[i].name = "猫猫 \(nextIndex)"
            nextIndex += 1
            changed = true
        }
        if changed { save() }
    }

    func save() {
        do {
            let data = try encoder.encode(state)
            try data.write(to: AppPaths.libraryURL, options: .atomic)
        } catch {
            lastError = "保存失败: \(error.localizedDescription)"
        }
    }

    func update(_ mutate: (inout LibraryState) -> Void) {
        mutate(&state)
        save()
    }

    func clip(id: String) -> PetClip? {
        state.clips.first { $0.id == id }
    }

    func removeClip(id: String) {
        update { s in
            s.clips.removeAll { $0.id == id }
            for i in s.clips.indices {
                s.clips[i].nextClipIDs.removeAll { $0 == id }
            }
            s.activeQueue.removeAll { $0 == id }
        }
        let dir = AppPaths.clipDirectory(id: id)
        try? FileManager.default.removeItem(at: dir)
    }

    func removeClips(ids: [String]) {
        for id in ids {
            removeClip(id: id)
        }
    }

    func setNextClips(for clipID: String, nextIDs: [String]) {
        update { s in
            guard let idx = s.clips.firstIndex(where: { $0.id == clipID }) else { return }
            s.clips[idx].nextClipIDs = nextIDs
        }
    }

    func setActiveQueue(_ ids: [String]) {
        update { s in
            let valid = ids.filter { id in s.clips.contains(where: { $0.id == id }) }
            s.activeQueue = valid
        }
    }

    func clearActiveQueue() {
        update { $0.activeQueue = [] }
    }

    /// Move selected rows up one step without breaking multi-selection blocks.
    @discardableResult
    func moveClipsUp(at indices: IndexSet) -> IndexSet {
        var newSelection = IndexSet()
        update { s in
            var clips = s.clips
            let sorted = indices.sorted()
            for i in sorted {
                if i > 0 && !indices.contains(i - 1) {
                    clips.swapAt(i, i - 1)
                    newSelection.insert(i - 1)
                } else {
                    newSelection.insert(i)
                }
            }
            s.clips = clips
            if !s.activeQueue.isEmpty {
                let q = Set(s.activeQueue)
                s.activeQueue = s.clips.map(\.id).filter { q.contains($0) }
            }
        }
        return newSelection
    }

    /// Move selected rows down one step.
    @discardableResult
    func moveClipsDown(at indices: IndexSet) -> IndexSet {
        var newSelection = IndexSet()
        update { s in
            var clips = s.clips
            let sorted = indices.sorted(by: >)
            for i in sorted {
                if i + 1 < clips.count && !indices.contains(i + 1) {
                    clips.swapAt(i, i + 1)
                    newSelection.insert(i + 1)
                } else {
                    newSelection.insert(i)
                }
            }
            s.clips = clips
            if !s.activeQueue.isEmpty {
                let q = Set(s.activeQueue)
                s.activeQueue = s.clips.map(\.id).filter { q.contains($0) }
            }
        }
        return newSelection
    }

    /// Copy source into app support and probe duration — does not key yet.
    func prepareStaging(from sourceURL: URL, displayName: String? = nil) throws -> ImportStaging {
        lastError = nil
        let fallbackName = Self.friendlyImportName(
            from: sourceURL,
            explicit: displayName,
            existingCount: state.clips.count
        )
        importProgress = ImportProgress(clipName: fallbackName, fraction: 0.05, message: "正在复制视频…")

        let clipID = UUID().uuidString
        let clipDir = AppPaths.clipDirectory(id: clipID)
        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let localURL = clipDir.appendingPathComponent("source.\(ext)")

        do {
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: localURL)
        } catch {
            importProgress = nil
            try? FileManager.default.removeItem(at: clipDir)
            throw ChromaKeyError.copyFailed(error.localizedDescription)
        }

        let duration: TimeInterval
        do {
            duration = try ChromaKeyProcessor.shared.probeDuration(url: localURL)
        } catch {
            // Still allow preview/import; duration fallback keeps sample times sane.
            duration = 5
        }

        importProgress = nil
        return ImportStaging(
            clipID: clipID,
            displayName: fallbackName,
            localSourceURL: localURL,
            clipDirectory: clipDir,
            duration: duration
        )
    }

    func discardStaging(_ staging: ImportStaging) {
        try? FileManager.default.removeItem(at: staging.clipDirectory)
        importProgress = nil
    }

    /// Full chromakey export after user accepted preview settings.
    func commitImport(staging: ImportStaging, settings: ChromaKeySettings) async -> PetClip? {
        lastError = nil
        importProgress = ImportProgress(
            clipName: staging.displayName,
            fraction: 0.2,
            message: "正在按预览参数导出透明帧…"
        )

        do {
            var clip = try await Task.detached(priority: .userInitiated) {
                try ChromaKeyProcessor.shared.importAndKey(
                    localSourceURL: staging.localSourceURL,
                    displayName: staging.displayName,
                    clipID: staging.clipID,
                    settings: settings
                )
            }.value
            clip.name = staging.displayName

            update { s in
                s.clips.append(clip)
                if s.autoLinkEnabled {
                    TransitionMatcher.rebuildAutoLinks(in: &s)
                }
            }
            importProgress = nil
            return clip
        } catch {
            importProgress = nil
            lastError = error.localizedDescription
            discardStaging(staging)
            return nil
        }
    }

    func toggleTag(clipID: String, tag: String) {
        update { s in
            guard let idx = s.clips.firstIndex(where: { $0.id == clipID }) else { return }
            if let existing = s.clips[idx].tags.firstIndex(of: tag) {
                s.clips[idx].tags.remove(at: existing)
            } else {
                s.clips[idx].tags.append(tag)
            }
        }
    }

    func renameClip(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update { s in
            guard let idx = s.clips.firstIndex(where: { $0.id == id }) else { return }
            s.clips[idx].name = trimmed
        }
    }

    /// Increment play count when the engine starts a clip. Does not post libraryDidChange.
    func recordPlay(id: String) {
        guard let idx = state.clips.firstIndex(where: { $0.id == id }) else { return }
        state.clips[idx].playCount += 1
        save()
    }

    /// Turn hash-like filenames into "猫猫 N".
    static func friendlyImportName(from url: URL, explicit: String?, existingCount: Int) -> String {
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let probe = PetClip(
            id: "",
            name: stem,
            sourcePath: "",
            frameCount: 0,
            fps: 24,
            displayWidth: 0,
            displayHeight: 0,
            firstFingerprint: [],
            lastFingerprint: [],
            nextClipIDs: [],
            createdAt: Date()
        )
        if probe.hasHashLikeName {
            return "猫猫 \(existingCount + 1)"
        }
        return stem
    }

    @discardableResult
    func rebuildAutoLinks() -> Int {
        var linkCount = 0
        update { s in
            linkCount = TransitionMatcher.rebuildAutoLinks(in: &s)
        }
        return linkCount
    }
}
