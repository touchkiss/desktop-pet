# Task 3 Report: LibraryState settings fields

## Status

**Complete**

## Summary

Extended `LibraryState` with teleport-related settings and backward-compatible JSON decoding defaults. Added shared default reminder messages constant to `TeleportMath` in DesktopPetCore.

## Changes

### `Sources/DesktopPetCore/TeleportMath.swift`

Added `public static let defaultReminderMessages` with three Chinese reminder strings:

- "喝点水吧"
- "站起来走走"
- "看看远处放松一下"

### `Sources/DesktopPet/Models.swift`

- Added `import DesktopPetCore`
- Added fields: `teleportEnabled`, `teleportFrequency`, `cursorNudgeEnabled`, `reminderMessages`
- Updated `LibraryState.empty` with defaults (`teleportEnabled: false`, `teleportFrequency: 0.5`, `cursorNudgeEnabled: false`, `reminderMessages: TeleportMath.defaultReminderMessages`)
- Extended `CodingKeys`, memberwise `init`, and custom `init(from:)` with `decodeIfPresent` defaults for all new fields

No other `LibraryState(...)` call sites required updates (only `.empty` constructs the struct directly).

## Verification

### Build

```
swift build
```

Result: **success** (build complete)

### Tests

```
swift test --filter TeleportMathTests
```

Result: **13 tests passed**, 0 failures

### Legacy JSON decode smoke (no app launch logs)

Ran a one-off Swift script mirroring the new `decodeIfPresent` logic against legacy JSON without teleport keys:

```json
{
  "clips": [],
  "playbackMode": "sequential",
  "petScale": 1.0,
  "alwaysOnTop": true,
  "clickThrough": false,
  "autoLinkThreshold": 0.82,
  "autoLinkEnabled": true
}
```

Decoded defaults:

| Field | Value |
|-------|-------|
| `teleportEnabled` | `false` |
| `teleportFrequency` | `0.5` |
| `cursorNudgeEnabled` | `false` |
| `reminderMessages` | `TeleportMath.defaultReminderMessages` |

Result: **decode smoke OK**

## Commits

None (per task overrides).

## Concerns / Follow-ups

- `LibraryState` lives in the executable target and is not importable by `DesktopPetTests`; decode coverage relies on the one-off smoke script above. A future task could move defaults or a decode helper to Core if automated tests are desired.
- Existing `library.json` on disk will load with teleport defaults until the user saves settings through the UI (future tasks).

## Files touched

| File | Action |
|------|--------|
| `Sources/DesktopPetCore/TeleportMath.swift` | Modified |
| `Sources/DesktopPet/Models.swift` | Modified |
