# Task Group 2: Library UI and Per-Asset Size Preview

Implement OpenSpec tasks 2.1–2.4 using the model/store APIs from task group 1.

## Established Interfaces

- `ClipTag.cursorPrey`, `ClipTag.cursorInteraction`
- `PetClip.cursorPreySettings: CursorPreySettings?`
- `CursorPreySettings.displaySize`
- `CursorInteractionPolicy.minimumPreyDisplaySize` = 16, maximum = 128, default = 48
- `LibraryStore.setCursorPreyEnabled(clipID:enabled:)`
- `LibraryStore.setCursorInteractionEnabled(clipID:enabled:)`
- `LibraryStore.setCursorPreyDisplaySize(clipID:displaySize:)`
- `PetClip.isCursorInteractionMaterial`

## Requirements

- Add detail checkboxes titled exactly “鼠标互动目标素材” and “鼠标互动猫片段”. They must reflect current tags and call the role-specific store APIs, preserving unrelated tags.
- When current clip is cursorPrey, show a size editor with 16–128 pt continuous slider, live integer pt label, and “恢复默认” button that sets 48 pt.
- Add a focused transparent animation preview that plays the current keyed PNG sequence at native fps and displays it at the configured point size, centered inside a stable checkerboard canvas. Slider/reset updates must be immediate and must not regenerate PNG files.
- Each clip reads/writes only its own settings.
- Explain in UI copy that both special roles are excluded from ordinary playback.
- After role changes, refresh detail/list/queue/transition display. If `engine.currentClipID` is now special, start the first ordinary playable clip; if none exist, stop safely.
- Do not alter the existing full clip preview semantics for ordinary clips.
- Keep changes minimal and macOS 13/Swift 5.9 compatible.

## Ownership

- Modify only `Sources/DesktopPet/LibraryWindowController.swift` unless a compile fix strictly requires one of the task-group-1 owned files.
- Do not edit OpenSpec artifacts, README, AppDelegate, PlaylistEngine implementation, overlay, or teleport files.
- You are not alone: preserve all current edits and do not revert user/other-agent changes.
- Do not commit.

## Verification

- Run `swift test` and `swift build` after implementation.
- Run `git diff --check -- Sources/DesktopPet/LibraryWindowController.swift`.
- Self-review callback lifetimes, timer invalidation, repeated detail reload, role exclusivity, empty playable list, and per-clip persistence.

Write the complete report to `.superpowers/sdd/cursor-prey-task-2-report.md`, including commands/results, files changed, self-review, and concerns. Return only DONE/DONE_WITH_CONCERNS/BLOCKED plus one-line verification and concerns.
