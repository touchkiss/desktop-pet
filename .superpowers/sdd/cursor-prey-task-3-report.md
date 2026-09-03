# Cursor-prey task group 3 report

## Result

Implemented OpenSpec tasks 3.1–3.4: cursor-interaction clips can replace an active
teleport end-hold for one pass, then resume only ordinary playback.

## TDD evidence

### RED

1. Added `Tests/DesktopPetTests/OneShotPlaybackStateTests.swift` before production
   code, covering captured return IDs, normal completion, cancellation, an invalid
   return fallback, an empty fallback, and idempotent repeated completion.
2. Ran `swift test --filter OneShotPlaybackStateTests`.
3. The sandboxed attempt could not write Xcode's user module cache. The permitted
   rerun reached the test compiler and failed as expected because
   `OneShotPlaybackState` did not exist (`cannot find 'OneShotPlaybackState' in scope`).

### GREEN

1. Added the pure `OneShotPlaybackState` state unit.
2. Ran `swift test --filter OneShotPlaybackStateTests`.
3. Passed: 5 tests, 0 failures.

## Changes

- Added `Sources/DesktopPetCore/OneShotPlaybackState.swift`, a pure idempotent
  state machine that captures the preferred ordinary return ID, resolves to that
  ID when valid, falls back to the first ordinary ID, or stops when no ordinary
  material remains.
- Added `Tests/DesktopPetTests/OneShotPlaybackStateTests.swift` with deterministic
  coverage for every required transition.
- Added `PlaylistEngine.playHeldCursorInteraction(id:completion:)`. It accepts
  only a valid `cursorInteraction` clip while an end hold is active, captures the
  held `pendingNextID`, starts the interaction on frame 1, and publishes its
  visible clip change.
- Added `PlaylistEngine.isPlayingOneShot` and
  `PlaylistEngine.cancelOneShotAndRestore()`. Ordinary `playClip(id:)` and
  `stop()` cancel the active one-shot without calling its completion handler.
- Updated the tick path so a one-shot completion bypasses `pickNext`,
  `clipFinishedHandler`, and `clipEndingSoonHandler`; it calls its completion
  once, then restores the resolved ordinary clip or safely stops.
- Updated library synchronization so a missing active one-shot source restores
  the best ordinary target, while a special current clip is accepted only when
  `isPlayingOneShot` is true.
- Kept notification publication after current-clip changes. The
  `playClip(id:notifyingObservers:)` overload permits callers to suppress a
  redundant notification where needed without altering state first.

## Verification

| Command | Result |
| --- | --- |
| `swift test --filter OneShotPlaybackStateTests` | RED: expected compile failure for missing state type; then GREEN: 5 tests passed. |
| `swift test` | Passed: 37 XCTest cases, 0 failures. |
| `swift build` | Passed: debug build complete. |
| `git diff --check -- Sources/DesktopPet/PlaylistEngine.swift Sources/DesktopPet/AppDelegate.swift Sources/DesktopPetCore/OneShotPlaybackState.swift Tests/DesktopPetTests/OneShotPlaybackStateTests.swift` | Passed: no whitespace errors. |

The normal Swift commands require access to Xcode's user-level module cache, so the
verification commands were rerun with that access after the sandboxed cache failure.

## State-transition and callback self-review

- **Start:** the one-shot API requires an existing clip-end hold, validates the
  interaction tag and renderability, captures `pendingNextID`, clears the hold,
  sets frame 1, then posts playback change.
- **Normal end:** the one-shot branch executes before ordinary next selection;
  it clears state before invoking its completion, so repeated ticks cannot call
  it twice, and no normal-finish or ending-soon callback runs for the special clip.
- **Preferred return invalid:** `OneShotPlaybackState` selects only from current
  `playableClips`, which already excludes both special roles; it falls back to
  the first valid ordinary clip.
- **No ordinary fallback:** state resolution selects `.stop`, and `stop()` clears
  the timer, current clip, frame index, hold, and one-shot context before posting
  the notification.
- **Cancellation:** ordinary `playClip(id:)` and `stop()` clear the state and
  completion closure without executing it. Source disappearance is handled in
  both the next tick and AppDelegate library synchronization by restoration
  without the normal completion callback.
- **Notifications:** every visible clip replacement and stop posts only after
  its observable state is updated; AppDelegate listens to library changes rather
  than playback notifications, avoiding a library-notification loop.

## Concerns

None.

## Review fixes

### Root cause

`completeOneShot()` cleared its state and invoked the completion callback before
unconditionally applying the captured ordinary-playback resolution. A synchronous
callback could call `stop()` or `playClip(id:)`, but the stale resolution would
then overwrite that newer visible playback choice. Separately, library
synchronization accepted any still-present special clip while a one-shot was
active, even if a role edit had removed `cursorInteraction` from its source.

### TDD evidence

1. Added `testCompletionResolutionOnlyAppliesWhileCompletedInteractionRemainsVisible`
   to `OneShotPlaybackStateTests` before the helper implementation.
2. Ran `swift test --filter OneShotPlaybackStateTests`; expected RED compilation
   failure: `OneShotPlaybackState` had no
   `shouldApplyCompletionResolution` member.
3. Added the pure helper and used it in `PlaylistEngine.completeOneShot()`.
4. Reran the focused test: GREEN, 6 tests passed with 0 failures.

### Changes

- `completeOneShot()` captures the completed interaction ID before clearing state,
  invokes the callback, then restores its captured resolution only when that same
  interaction is still the visible current clip. A callback that stops playback
  or selects another clip now wins.
- Added the small deterministic `OneShotPlaybackState.shouldApplyCompletionResolution`
  helper and its direct state-test coverage.
- `AppDelegate.handleLibraryChange()` now cancels and restores an active one-shot
  when its still-present current source no longer has the `cursorInteraction`
  tag, instead of restarting the invalid role-changed clip.

### Verification

| Command | Result |
| --- | --- |
| `swift test --filter OneShotPlaybackStateTests` | RED as above, then GREEN: 6 tests, 0 failures. |
| `swift test` | Passed: 38 XCTest cases, 0 failures. |
| `swift build` | Passed: debug build complete. |
| `git diff --check -- Sources/DesktopPet/PlaylistEngine.swift Sources/DesktopPet/AppDelegate.swift Sources/DesktopPetCore/OneShotPlaybackState.swift Tests/DesktopPetTests/OneShotPlaybackStateTests.swift` | Passed: no whitespace errors. |

### Review self-check

- A completion callback that calls `stop()` leaves `currentClipID == nil`; the
  guard returns without stale restoration.
- A callback that selects another clip changes `currentClipID`; the guard returns
  without stale restoration.
- A callback that leaves the completed interaction current permits normal queued
  restoration exactly as before.
- A deleted source is handled by the existing missing-clip path; a present but
  retagged source is handled by the new role-validation path.

## Second review fixes

### Root cause

The first reentrancy guard compared only the interaction clip ID after running
the completion callback. A callback could start a new playback session for that
same ID, leaving the ID unchanged and allowing the old one-shot resolution to
overwrite the new session.

### TDD evidence

1. Replaced the ID-based helper test with
   `testCompletionResolutionRejectsANewSameIDSessionWithChangedRevision` before
   the implementation.
2. Ran `swift test --filter OneShotPlaybackStateTests`; expected RED compilation
   failure reported the old helper's incompatible `completedInteractionID` /
   `currentClipID` signature.
3. Implemented the revision comparison and reran the focused suite: GREEN,
   6 tests passed with 0 failures.

### Changes

- Added a monotonic `playbackRevision` to `PlaylistEngine`.
- It advances for every explicit visible playback command/session start:
  initial attachment assignment, `playClip`, `stop`, held one-shot start, and
  both same-clip hold-resume paths. Commands that transition to another clip
  use `playClip` and therefore advance through the same path.
- `completeOneShot()` captures the revision immediately before invoking its
  completion handler. Its previously captured resolution applies only if the
  revision is unchanged after that synchronous callback returns.
- Updated the pure helper to compare revisions rather than IDs. Thus, a callback
  that restarts the same clip is correctly treated as a newer playback session
  and cannot be overwritten by stale restoration.

### Verification

| Command | Result |
| --- | --- |
| `swift test --filter OneShotPlaybackStateTests` | RED as above, then GREEN: 6 tests, 0 failures. |
| `swift test` | Passed: 38 XCTest cases, 0 failures. |
| `swift build` | Passed: debug build complete. |
| `git diff --check -- Sources/DesktopPet/PlaylistEngine.swift Sources/DesktopPet/AppDelegate.swift Sources/DesktopPetCore/OneShotPlaybackState.swift Tests/DesktopPetTests/OneShotPlaybackStateTests.swift` | Passed: no whitespace errors. |

### Review self-check

- A callback that stops, starts another clip, or starts a new pass of the same
  clip advances the revision; the stale resolution is rejected.
- A callback that makes no playback command leaves the revision unchanged; the
  ordinary return resolution proceeds exactly once.
- The callback is still read and cleared before invocation, so repeated ticks
  cannot execute it twice.
