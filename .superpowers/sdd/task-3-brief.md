### Task 3: LibraryState settings fields

**Files:**
- Modify: `Sources/DesktopPet/Models.swift`
- Create: `Tests/DesktopPetTests/LibraryStateTeleportDecodingTests.swift` — **only if** decode helpers are moved to Core; otherwise verify with a small decode test by duplicating JSON round-trip in a new Core-free approach:

Because `LibraryState` lives in the executable module (not importable by tests), verify decode via a **manual** build + a focused runtime assert in DEBUG, **or** move only the default constants to Core.

**Preferred:** keep fields in `Models.swift`; add decode defaults; cover with manual check in Step 4. Pure defaults constant in Core for reuse:

- Modify: `Sources/DesktopPetCore/TeleportMath.swift` — add `public static let defaultReminderMessages`

**Interfaces:**
- Produces on `LibraryState`: `teleportEnabled`, `teleportFrequency`, `cursorNudgeEnabled`, `reminderMessages`
- `LibraryState.empty` and `init(from:)` use defaults when keys missing

- [ ] **Step 1: Add default messages constant to Core**

```swift
// in TeleportMath
public static let defaultReminderMessages = [
    "喝点水吧",
    "站起来走走",
    "看看远处放松一下"
]
```

- [ ] **Step 2: Extend LibraryState**

In `Models.swift`, add `import DesktopPetCore` and update `LibraryState`:

```swift
struct LibraryState: Codable {
    var clips: [PetClip]
    var playbackMode: PlaybackMode
    var petScale: Double
    var alwaysOnTop: Bool
    var clickThrough: Bool
    var autoLinkThreshold: Double
    var autoLinkEnabled: Bool
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
```

Update any other `LibraryState(...)` memberwise call sites if the compiler reports missing arguments (only `.empty` and `init(from:)` should construct it today).

- [ ] **Step 3: Build**

Run: `swift build`

Expected: success. Existing `library.json` without new keys still loads via `decodeIfPresent`.

- [ ] **Step 4: Manual decode smoke**

Temporarily log on launch once, or run a one-off in lldb — confirm old library loads with `teleportEnabled == false`. Remove any temporary log before finishing the task.

---

