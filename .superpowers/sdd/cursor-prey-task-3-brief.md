# Task Group 3: One-Shot Interaction Playback

Implement OpenSpec tasks 3.1–3.4 with TDD.

## Current Context

- `PlaylistEngine` holds a normal clip at its last frame during teleport via `holdingAtEnd` and `pendingNextID`.
- `resumeAfterHold(playNext:)` currently releases that hold.
- Task group 2 changed `stop()` to clear `currentClipID` and added `playClip(id:notifyingObservers:)`.
- Special clips are excluded from `LibraryState.playableClips`, but direct `playClip(id:)` can still play one.

## Requirements

- Write a failing deterministic test first for a pure one-shot state unit in `DesktopPetCore`, covering: start with captured ordinary return ID, normal completion, cancellation, invalid return fallback, empty fallback, and repeated completion being harmless.
- Add the minimal pure state type under `Sources/DesktopPetCore/` and tests under `Tests/DesktopPetTests/`.
- Extend `PlaylistEngine` with a focused API to replace an active clip-end hold with one specified `cursorInteraction` clip starting at frame 1. Capture the held `pendingNextID` as the preferred return target.
- When the one-shot reaches its last frame, do not call normal `pickNext`, `clipFinishedHandler`, or teleport `clipEndingSoonHandler`. Invoke its completion exactly once, then play the captured return clip if it is still in `playableClips`, otherwise the first `playableClips`; if none exist, stop and clear current.
- `stop()` and ordinary `playClip(id:)` must cancel one-shot state without accidentally invoking normal completion twice. Provide a way for integration code to query whether a one-shot is active.
- If the one-shot source clip disappears, cancel it and restore the best valid ordinary target or safely stop. AppDelegate library synchronization must allow a valid special `currentClipID` only while the engine reports an active one-shot.
- Do not let one-shot frames emit the ending-soon teleport callback.
- Post playback notifications after visible current-clip changes so UI badges refresh, without notification recursion.

## Ownership

- Modify/create only:
  - `Sources/DesktopPet/PlaylistEngine.swift`
  - `Sources/DesktopPet/AppDelegate.swift` if required for library synchronization
  - one new focused state file in `Sources/DesktopPetCore/`
  - one new focused test file in `Tests/DesktopPetTests/`
- Preserve all current user and other-agent edits; do not revert anything.
- Do not edit OpenSpec artifacts, UI layout, overlay, teleport controller, or README.
- Do not commit.

## Verification

1. Run the new filtered test before production implementation and record expected RED.
2. Run the filtered test GREEN.
3. Run full `swift test` and `swift build`.
4. Run diff check and self-review every state transition/callback.

Write the full report to `.superpowers/sdd/cursor-prey-task-3-report.md` with RED/GREEN evidence, files, self-review, and concerns. Return only status, one-line verification, and concerns.
