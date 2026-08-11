import Foundation
import DesktopPetCore

enum PlaybackMode: String, Codable, CaseIterable, Identifiable {
    case sequential
    case random
    case graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .random: return "随机播放"
        case .graph: return "衔接播放"
        }
    }
}

struct PetClip: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var sourcePath: String
    var frameCount: Int
    var fps: Double
    var displayWidth: Int
    var displayHeight: Int
    var firstFingerprint: [Float]
    var lastFingerprint: [Float]
    /// Manual / auto-suggested next clip IDs (used in graph mode).
    var nextClipIDs: [String]
    var createdAt: Date
    /// How many times this clip has been started by the playlist engine.
    var playCount: Int

    var framesDirectoryName: String { id }

    var duration: TimeInterval {
        guard fps > 0 else { return 0 }
        return Double(frameCount) / fps
    }

    /// True when the stored name looks like a content-hash filename.
    var hasHashLikeName: Bool {
        let stem = name
            .replacingOccurrences(of: "_raw", with: "")
            .replacingOccurrences(of: "-raw", with: "")
        guard stem.count >= 16 else { return false }
        return stem.allSatisfy { $0.isHexDigit }
    }

    func displayTitle(indexInLibrary: Int) -> String {
        if hasHashLikeName {
            return "猫猫 \(indexInLibrary + 1)"
        }
        return name.isEmpty ? "未命名片段" : name
    }

    var importedAtText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d HH:mm"
        return f.string(from: createdAt)
    }

    var metaText: String {
        String(format: "%.1f秒 · %d帧 · %@", duration, frameCount, importedAtText)
    }

    var playCountText: String {
        "\(playCount) 次"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sourcePath, frameCount, fps, displayWidth, displayHeight
        case firstFingerprint, lastFingerprint, nextClipIDs, createdAt, playCount
    }

    init(
        id: String,
        name: String,
        sourcePath: String,
        frameCount: Int,
        fps: Double,
        displayWidth: Int,
        displayHeight: Int,
        firstFingerprint: [Float],
        lastFingerprint: [Float],
        nextClipIDs: [String],
        createdAt: Date,
        playCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.frameCount = frameCount
        self.fps = fps
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.firstFingerprint = firstFingerprint
        self.lastFingerprint = lastFingerprint
        self.nextClipIDs = nextClipIDs
        self.createdAt = createdAt
        self.playCount = playCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        frameCount = try c.decode(Int.self, forKey: .frameCount)
        fps = try c.decode(Double.self, forKey: .fps)
        displayWidth = try c.decode(Int.self, forKey: .displayWidth)
        displayHeight = try c.decode(Int.self, forKey: .displayHeight)
        firstFingerprint = try c.decode([Float].self, forKey: .firstFingerprint)
        lastFingerprint = try c.decode([Float].self, forKey: .lastFingerprint)
        nextClipIDs = try c.decode([String].self, forKey: .nextClipIDs)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
    }
}

struct LibraryState: Codable {
    var clips: [PetClip]
    var playbackMode: PlaybackMode
    var petScale: Double
    var alwaysOnTop: Bool
    var clickThrough: Bool
    /// Similarity threshold 0...1 for auto transition edges.
    var autoLinkThreshold: Double
    var autoLinkEnabled: Bool
    /// If non-empty, playback only cycles through these clip IDs (in order for sequential).
    var activeQueue: [String]
    var teleportEnabled: Bool
    var teleportFrequency: Double
    var cursorNudgeEnabled: Bool
    var reminderMessages: [String]

    static let empty = LibraryState(
        clips: [],
        playbackMode: .sequential,
        petScale: 1.0,
        alwaysOnTop: true,
        clickThrough: false,
        autoLinkThreshold: 0.82,
        autoLinkEnabled: true,
        activeQueue: [],
        teleportEnabled: false,
        teleportFrequency: 0.5,
        cursorNudgeEnabled: false,
        reminderMessages: TeleportMath.defaultReminderMessages
    )

    /// Clips participating in the current play cycle.
    var playableClips: [PetClip] {
        if activeQueue.isEmpty { return clips }
        return activeQueue.compactMap { id in clips.first { $0.id == id } }
    }

    enum CodingKeys: String, CodingKey {
        case clips, playbackMode, petScale, alwaysOnTop, clickThrough
        case autoLinkThreshold, autoLinkEnabled, activeQueue
        case teleportEnabled, teleportFrequency, cursorNudgeEnabled, reminderMessages
    }

    init(
        clips: [PetClip],
        playbackMode: PlaybackMode,
        petScale: Double,
        alwaysOnTop: Bool,
        clickThrough: Bool,
        autoLinkThreshold: Double,
        autoLinkEnabled: Bool,
        activeQueue: [String],
        teleportEnabled: Bool,
        teleportFrequency: Double,
        cursorNudgeEnabled: Bool,
        reminderMessages: [String]
    ) {
        self.clips = clips
        self.playbackMode = playbackMode
        self.petScale = petScale
        self.alwaysOnTop = alwaysOnTop
        self.clickThrough = clickThrough
        self.autoLinkThreshold = autoLinkThreshold
        self.autoLinkEnabled = autoLinkEnabled
        self.activeQueue = activeQueue
        self.teleportEnabled = teleportEnabled
        self.teleportFrequency = teleportFrequency
        self.cursorNudgeEnabled = cursorNudgeEnabled
        self.reminderMessages = reminderMessages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decode([PetClip].self, forKey: .clips)
        playbackMode = try c.decode(PlaybackMode.self, forKey: .playbackMode)
        petScale = try c.decode(Double.self, forKey: .petScale)
        alwaysOnTop = try c.decode(Bool.self, forKey: .alwaysOnTop)
        clickThrough = try c.decode(Bool.self, forKey: .clickThrough)
        autoLinkThreshold = try c.decode(Double.self, forKey: .autoLinkThreshold)
        autoLinkEnabled = try c.decode(Bool.self, forKey: .autoLinkEnabled)
        activeQueue = try c.decodeIfPresent([String].self, forKey: .activeQueue) ?? []
        teleportEnabled = try c.decodeIfPresent(Bool.self, forKey: .teleportEnabled) ?? false
        teleportFrequency = try c.decodeIfPresent(Double.self, forKey: .teleportFrequency) ?? 0.5
        cursorNudgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorNudgeEnabled) ?? false
        reminderMessages = try c.decodeIfPresent([String].self, forKey: .reminderMessages)
            ?? TeleportMath.defaultReminderMessages
    }
}

struct ImportProgress: Equatable {
    var clipName: String
    var fraction: Double
    var message: String
}
