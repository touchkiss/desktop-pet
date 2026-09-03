# Task Group 5: Teleport Interaction Orchestration and Cleanup

Implement OpenSpec tasks 5.1–5.6 with TDD for any new pure session state.

## Established Interfaces

- `CursorInteractionPolicy.isInteractionEligible(isAutonomous:landingMode:hasPreyCandidate:hasInteractionCandidate:)`
- `ClipTag.cursorPrey`, `ClipTag.cursorInteraction`, `CursorPreySettings`
- `LibraryState.playableClips` excludes special materials.
- `PlaylistEngine.playHeldCursorInteraction(id:completion:) -> Bool`
- `PlaylistEngine.isPlayingOneShot`, `cancelOneShotAndRestore()`
- `CursorPreyOverlayController.onFailure`, `isActive`, `start(clip:settings:) -> Bool`, `stop()`
- AppDelegate already calls `teleportController.syncFromStore()` on library changes and `teleportController.stop()` before quit.

## Requirements

- Distinguish trip provenance in `TeleportController`: only the normal clip-end random trip is autonomous. `summonToCursor` (hotkey/pomodoro/download) and `previewTrip` are explicit/non-autonomous.
- After the landing mode is resolved for an autonomous trip, prepare an interaction only when it is `.cursorNudge`, there is no explicit arrival message, and at least one valid prey plus one valid interaction-cat candidate exists. Select each independently at random.
- Valid prey candidates require tag, renderable positive frames/fps, and settings (use preserved/default settings if needed). Valid interaction candidates require tag and renderable positive frames/fps. Do not select a single clip for both roles.
- Missing candidates or initial overlay/start failure must leave the cursor visible and follow the existing cursor-reminder fallback.
- Add a small pure session state under `DesktopPetCore` and focused test RED/GREEN if it helps represent pending/active/idempotent clear.
- Implement one shared landing-preparation path used by normal appear and integrated swarm arrival:
  1. start the prey overlay;
  2. replace the active engine hold with the selected interaction clip from frame 1;
  3. only then reveal/start the cat appear presentation using that clip.
  If either start fails, stop/clear partial interaction and release the normal held playback.
- On successful start, suppress the normal random reminder bubble for this cursor landing. When no interaction starts, preserve the existing bubble behavior exactly.
- The interaction-cat normal completion closure must stop the overlay and clear session state but must not issue a competing playback command; PlaylistEngine owns ordinary restoration.
- While pending/active, prevent a second autonomous teleport. A manual summon/preview/new explicit trip may cancel active interaction first, restore ordinary playback, then start its non-interactive trip.
- One idempotent cleanup path must cover drag/fling callback, hide, new trip, overlay failure, source deletion/retagging via `syncFromStore`, controller stop/app quit, and any existing teleport cancellation. Pending cleanup clears without advancing playback; active cleanup stops overlay and calls `cancelOneShotAndRestore()` only when a one-shot is active.
- Ensure `holdingEngine` bookkeeping is consumed exactly once. Normal, swarm, fallback, cancellation, and interaction paths must not freeze or double-advance playback.
- Keep hotkey summon, pomodoro, download reminder, and effect preview behavior unchanged and non-interactive.

## Ownership

- Primary: `Sources/DesktopPet/TeleportController.swift`
- Optional focused pure state/test under `Sources/DesktopPetCore/` and `Tests/DesktopPetTests/`
- Modify `CursorPreyOverlayController.swift`, `PlaylistEngine.swift`, or `AppDelegate.swift` only for a strictly necessary integration correction, and document it.
- Do not edit library UI, models/store, README, or OpenSpec artifacts.
- Preserve all current edits; do not revert. Do not commit.

## Verification

1. Run focused session test RED then GREEN if added.
2. Run `swift test` and `swift build`.
3. Run diff check.
4. Self-review all effect variants (classic, bridge, swarm), fallback, bubble suppression, manual paths, hold ownership, overlay failure, repeated cleanup, library change, drag/hide/quit.

Write full evidence to `.superpowers/sdd/cursor-prey-task-5-report.md`. Return status, one-line verification, and concerns.
