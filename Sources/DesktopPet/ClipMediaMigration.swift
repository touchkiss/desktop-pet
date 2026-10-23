import Foundation

/// Serial, resumable migration. No library metadata is rewritten.
enum ClipMediaMigration {
    static func convert(_ clip: PetClip, keepBackup: Bool, directory: URL? = nil) throws {
        guard clip.frameCount > 0, clip.fps.isFinite, clip.fps > 0 else {
            throw ChromaKeyError.invalidVideo
        }
        let manager = FileManager.default
        let frames = directory?.appendingPathComponent("frames", isDirectory: true)
            ?? AppPaths.frameURL(clipID: clip.id, index: 1).deletingLastPathComponent()
        let backup = frames.deletingLastPathComponent().appendingPathComponent("png-backup", isDirectory: true)
        let names = Set(["00001.png", String(format: "%05d.png", clip.frameCount)])
        let existing = (try? manager.contentsOfDirectory(atPath: frames.path)) ?? []
        let movie = frames.deletingLastPathComponent().appendingPathComponent("animation.mov")
        let receiptURL = movie.deletingPathExtension().appendingPathExtension("validated.json")
        let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
        let needsApertureRepair = (clip.displayHeight % 2 != 0 || clip.displayWidth % 2 != 0) && receipt?.codecVersion != AlphaVideoEncoder.codecVersion
        let movieIsUnchanged = !needsApertureRepair && receipt?.matches(movie: movie, clip: clip) == true
        if movieIsUnchanged && Set(existing) == names { return }

        func completeSequence(_ directory: URL) -> Bool {
            let entries = Set((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
            return (1...clip.frameCount).allSatisfy { entries.contains(String(format: "%05d.png", $0)) }
        }
        let source = completeSequence(frames) ? frames : backup
        let frameURLs = (1...clip.frameCount).map {
            source.appendingPathComponent(String(format: "%05d.png", $0))
        }
        if manager.fileExists(atPath: movie.path), !movieIsUnchanged {
            do {
                if needsApertureRepair { throw ChromaKeyError.processFailed("升级奇数高度视频裁切") }
                _ = try AlphaVideoEncoder.validate(url: movie, expectedFrameCount: clip.frameCount, fps: clip.fps)
            } catch {
                guard completeSequence(source) else { throw error }
                // Preserve a damaged movie for inspection, then recover from the sequence backup.
                try manager.moveItem(at: movie, to: movie.deletingLastPathComponent()
                    .appendingPathComponent("invalid-animation-\(UUID().uuidString).mov"))
            }
        }
        if !manager.fileExists(atPath: movie.path) {
            try AlphaVideoEncoder.encode(frameURLs: frameURLs, fps: clip.fps, outputURL: movie)
        }
        let validated = try Receipt(movie: movie, clip: clip)
        try JSONEncoder().encode(validated).write(to: receiptURL, options: .atomic)
        if Set(existing) == names { return }
        // Prepare both endpoints before touching the source or recovery sequence.
        let replacement = frames.deletingLastPathComponent()
            .appendingPathComponent("thumbnails-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: replacement) }
        for name in names {
            let original = source.appendingPathComponent(name)
            try manager.copyItem(at: original, to: replacement.appendingPathComponent(name))
        }
        if manager.fileExists(atPath: frames.path) {
            // A restored sequence may coexist with its backup after an interrupted older run.
            // Preserve both instead of overwriting either or making retries permanently fail.
            let archive = manager.fileExists(atPath: backup.path)
                ? frames.deletingLastPathComponent().appendingPathComponent("png-recovery-\(UUID().uuidString)")
                : backup
            try manager.moveItem(at: frames, to: archive)
        }
        do {
            try manager.moveItem(at: replacement, to: frames)
        } catch {
            if !manager.fileExists(atPath: frames.path) {
                try? manager.moveItem(at: backup, to: frames)
            }
            throw error
        }
        // New imports have no user-owned legacy sequence to retain.
        if !keepBackup, manager.fileExists(atPath: backup.path) {
            try manager.removeItem(at: backup)
        }
    }

    private struct Receipt: Codable {
        let size: Int
        let modified: Date
        let frameCount: Int
        let fps: Double
        let codecVersion: Int

        init(movie: URL, clip: PetClip) throws {
            let values = try movie.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize, let modified = values.contentModificationDate else {
                throw ChromaKeyError.invalidVideo
            }
            self.size = size
            self.modified = modified
            frameCount = clip.frameCount
            fps = clip.fps
            codecVersion = AlphaVideoEncoder.codecVersion
        }

        func matches(movie: URL, clip: PetClip) -> Bool {
            guard let current = try? Receipt(movie: movie, clip: clip) else { return false }
            return current.size == size && current.modified == modified
                && current.frameCount == frameCount && current.fps == fps
        }
    }

}

@MainActor
final class ClipMediaMigrationController {
    private var task: Task<Void, Never>?
    private(set) var isRunning = false
    var onProgress: ((String) -> Void)?
    var onClipConverted: ((String) -> Void)?

    func start(clips: [PetClip]) {
        guard !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            var failures: [String] = []
            for (index, clip) in clips.enumerated() {
                guard !Task.isCancelled else { break }
                self?.onProgress?("素材升级 \(index + 1)/\(clips.count)：\(clip.name)")
                do {
                    try await Task.detached(priority: .utility) {
                        try ClipMediaMigration.convert(clip, keepBackup: true)
                    }.value
                    self?.onClipConverted?(clip.id)
                } catch {
                    failures.append("\(clip.name)：\(error.localizedDescription)")
                }
            }
            self?.isRunning = false
            if failures.isEmpty {
                self?.onProgress?("透明视频升级完成（\(clips.count) 个片段）")
            } else {
                let report = AppPaths.supportRoot.appendingPathComponent("media-migration-errors.txt")
                try? failures.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
                self?.onProgress?("素材升级：\(failures.count) 个失败，点击重试")
                NSLog("DesktopPet migration failures: %@", failures.joined(separator: "\n"))
            }
            self?.task = nil
        }
    }
}
