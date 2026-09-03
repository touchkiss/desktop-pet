# Task Group 5 Report: Teleport Interaction Orchestration and Cleanup

## Status

DONE

Implemented OpenSpec tasks 5.1–5.6. The change is scoped to `TeleportController` plus a focused pure session state and its XCTest coverage. No commit was created, and no library UI, model/store, README, AppDelegate, PlaylistEngine, overlay controller, or OpenSpec artifact was modified by this task.

## Implementation

### Provenance and candidate preparation

- Added explicit trip provenance in `TeleportController`.
  - The clip-ending random trip is the only `.autonomous` source.
  - effect preview, hotkey summon, pomodoro summon, and download summon all use `.explicit`.
- Interaction eligibility is evaluated only after `resolveDestination()` has finalized the landing mode, and only for an autonomous `.cursorNudge` with no explicit arrival message.
- Candidate filtering requires the appropriate role tag, positive frame count, finite positive fps, and positive render dimensions.
- Prey and interaction clips are selected from their own random pools. Pairing excludes the selected prey ID from the cat-action draw, including defensive handling of malformed legacy clips carrying both tags.
- Missing prey settings use `CursorPreySettings()` so preserved settings are used when present and the 48 pt default is used otherwise.

### Shared landing orchestration

- Classic appear and integrated swarm arrival now enter one shared landing-preparation path.
- A pending interaction starts in the required order:
  1. start the cursor-prey overlay and make its first frame visible;
  2. replace the engine's clip-end hold with the interaction cat one-shot at frame 1;
  3. consume `holdingEngine`, force the pet's frame-1 refresh, place the landing frame, then reveal/start the cat presentation.
- Successful interaction presentation is synchronous after the forced refresh so even a valid one-frame action cannot finish before its first frame becomes the appearance frame.
- Ordinary classic landings retain the existing 50 ms settling delay; ordinary swarm handoff remains immediate.
- Overlay or one-shot start failure stops partial overlay state, restores the cursor, clears the pending session, releases the ordinary engine hold once, and leaves reminder fallback enabled.

### Completion, suppression, and cleanup

- Successful interaction start suppresses the normal random cursor reminder for that trip only. Missing candidates and initial start failures preserve the existing random/explicit bubble path.
- The one-shot's normal completion callback invokes shared cleanup with playback restoration disabled. It stops the overlay and clears the session but issues no playback command; `PlaylistEngine` remains the owner of ordinary restoration.
- Autonomous clip-ending teleports are blocked while the session is pending or active.
- An explicit preview/summon can cancel a pending/active interaction first, restore ordinary playback when needed, and then begin its non-interactive trip.
- One idempotent cleanup method is reached by drag/fling cancellation, hide, explicit replacement trip, overlay failure, invalid/deleted/retagged sources during `syncFromStore`, controller stop/app quit, swarm setup failure, and existing teleport cancellation.
  - pending cleanup clears/stops only and never advances playback;
  - active cleanup stops the overlay and calls `cancelOneShotAndRestore()` only while the engine reports an active one-shot;
  - repeated cleanup receives no phase result and cannot restore playback twice.
- `holdingEngine` is set only when the teleport declines an ordinary clip end, is consumed without advancing after successful `playHeldCursorInteraction`, and is released exactly once on ordinary/fallback/cancellation paths.

## TDD Evidence

### RED

Test added first: `Tests/DesktopPetTests/CursorInteractionSessionStateTests.swift`.

The initial sandboxed command was blocked before compilation by SwiftPM/user cache sandbox permissions, so it was not counted as RED. The command was rerun outside that filesystem sandbox with task-scoped caches:

```text
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/cursor-prey-task5-swift-cache \
CLANG_MODULE_CACHE_PATH=/tmp/cursor-prey-task5-clang-cache \
swift test --filter CursorInteractionSessionStateTests
```

Expected failure observed before production state existed:

```text
error: cannot find 'CursorInteractionSessionState' in scope
error: Build failed
```

### GREEN

After adding `Sources/DesktopPetCore/CursorInteractionSessionState.swift`, the same focused command passed:

```text
Executed 6 tests, with 0 failures (0 unexpected)
```

The focused suite covers distinct pair preparation, same-ID rejection, pending-only activation, pending clear, active clear, repeated idempotent clear, and refusal to replace pending/active sessions.

## Final Verification

All verification commands used task-scoped Swift/Clang module caches because the default user cache is not writable in the managed environment.

1. Focused state verification:

```text
swift test --filter CursorInteractionSessionStateTests
Executed 6 tests, with 0 failures (0 unexpected)
```

2. Full suite:

```text
swift test
Executed 49 tests, with 0 failures (0 unexpected)
```

3. Full debug build:

```text
swift build
Build complete! (0.19秒)
```

4. Diff hygiene:

```text
git diff --check
exit 0, no whitespace errors
```

Scoped working-tree result:

```text
 M Sources/DesktopPet/TeleportController.swift
?? Sources/DesktopPetCore/CursorInteractionSessionState.swift
?? Tests/DesktopPetTests/CursorInteractionSessionStateTests.swift
?? .superpowers/sdd/cursor-prey-task-5-report.md
```

## Self-review Matrix

| Path | Interaction behavior | Playback/hold ownership | Bubble behavior |
| --- | --- | --- | --- |
| Classic appear, eligible | overlay → held one-shot → frame-1 appear | hold consumed, ordinary restore owned by engine | random reminder suppressed |
| Bridge arrival, eligible | same shared classic landing preparation | same as classic | random reminder suppressed |
| Swarm arrival, eligible | same preparation before live-pet handoff | hold consumed once | random reminder suppressed |
| Any effect, missing candidate | no overlay or one-shot | ordinary hold released once | existing reminder preserved |
| Overlay initial failure | cursor never remains hidden; pending clear | ordinary hold released once | existing reminder preserved |
| One-shot start failure | partial overlay stopped/unhidden | ordinary hold released once | existing reminder preserved |
| Normal one-shot completion | overlay/session cleanup only | engine applies its captured resolution | already suppressed for successful trip |
| Drag/fling/hide/stop/quit | idempotent shared cleanup | active one-shot restored only once; pending does not advance | in-flight trip cancelled |
| Overlay runtime failure | shared active cleanup | active one-shot cancelled/restored | successful-trip suppression retained |
| Source delete/retag | `syncFromStore` invalidates pending/active pair | pending waits for landing fallback; active restores ordinary | pending landing falls back normally |
| Manual summon/preview during interaction | cancels pending/active first, then explicit trip | active restore precedes new trip | existing explicit/random arrival bubble retained |

## Files Changed by Task 5

- `Sources/DesktopPet/TeleportController.swift`
- `Sources/DesktopPetCore/CursorInteractionSessionState.swift`
- `Tests/DesktopPetTests/CursorInteractionSessionStateTests.swift`
- `.superpowers/sdd/cursor-prey-task-5-report.md`

## Concerns

- The deterministic lifecycle and all project tests are automated, but AppKit window/cursor timing and visual alignment still require the later manual validation described by OpenSpec task group 6; those manual checks are outside this task group's requested verification.

## Review fixes

### Abnormal one-shot termination ownership

- `PlaylistEngine.playHeldCursorInteraction` now accepts separate normal-completion and abnormal-cancellation callbacks. Cancellation reports one of `.replacedByPlayback`, `.stopped`, `.requestedRestore`, or `.sourceInvalidated`.
- `OneShotPlaybackState.cancel()` returns the terminated interaction ID exactly once. The engine uses that result as the authoritative gate for one cancellation notification; repeated cancellation cannot notify again.
- External ordinary `playClip`, `stop`, explicit `cancelOneShotAndRestore`, missing current source during `tick`, and deletion/retag branches in `AppDelegate` all route through abnormal cancellation.
- `TeleportController` registers a cancellation callback tied to the selected interaction ID. The callback only stops the overlay and clears active session state; it never starts/stops/restores playback, because the engine operation that raised it owns that mutation.
- `syncFromStore` lets `.sourceInvalidated` terminate an active engine one-shot first, so the authoritative callback clears the overlay/session before the engine restores ordinary playback. Pending invalid sessions still clear without advancing playback.
- Normal one-shot completion clears the cancellation callback without invoking it, calls only the normal completion closure, then applies the ordinary resolution if the playback generation is unchanged.
- All handlers are detached before invocation. `playClip`, `stop`, cancellation restoration, and normal completion compare their captured revision after callbacks, so a reentrant newer playback request wins and the older operation cannot overwrite it.

### Selected interaction frame validation

- Interaction candidates now require `frames/00001.png` to exist, decode as `NSImage`, and report positive finite width and height in addition to valid tag/frame-count/fps/model dimensions.
- The selected interaction is revalidated immediately before the prey overlay starts. An invalid or newly missing first frame therefore leaves the system cursor visible, does not start/suppress the one-shot, releases the ordinary hold through the existing fallback, and preserves the reminder bubble.

### Timer generation safety

- Every `restartTimer()` invalidates the prior timer and increments `timerRevision`; the scheduled timer and queued `@MainActor` task capture that revision.
- `tick(timerRevision:)` rejects stale queued work through `PlaybackRevisionPolicy` before reading or mutating playback.
- Timer setup now requires finite positive fps and a finite positive `1 / fps` interval. `playHeldCursorInteraction` applies the same timing validation before reporting success.

### Activation rollback and petting isolation

- `cursorInteraction.activate()` is now guarded. If it unexpectedly fails after the one-shot consumed the hold, rollback clears pending session state, restores the cursor/overlay, cancels and restores the one-shot, leaves `holdingEngine` consumed, and returns to normal reminder fallback without a second hold advance.
- `AppDelegate.handlePetTapped` excludes all cursor-prey/cursor-interaction materials even if malformed or legacy data also carries the `petting` tag, so petting cannot start a special clip as ordinary playback.

### Review-fix TDD evidence

Tests were written before the new Core behavior:

```text
swift test --filter PlaybackRevisionPolicyTests
```

RED failures:

```text
error: cannot find 'PlaybackRevisionPolicy' in scope
error: cannot convert value of type '()' to expected argument type 'String'
error: Build failed
```

The failures prove both missing generation policy and missing cancellation identity/idempotency behavior.

Focused GREEN evidence:

```text
swift test --filter PlaybackRevisionPolicyTests
Executed 2 tests, with 0 failures (0 unexpected)

swift test --filter OneShotPlaybackStateTests
Executed 6 tests, with 0 failures (0 unexpected)
```

The new/updated deterministic coverage verifies exact-generation acceptance, stale-generation rejection, and that cancellation returns the active interaction exactly once before becoming harmless.

### Review-fix final verification

All commands used the task-scoped Swift/Clang caches documented earlier.

```text
swift test
Executed 51 tests, with 0 failures (0 unexpected)

swift build
Build complete! (0.29秒)

git diff --check
exit 0, no whitespace errors
```

Additional files modified by the review fixes:

- `Sources/DesktopPet/PlaylistEngine.swift`
- `Sources/DesktopPet/AppDelegate.swift`
- `Sources/DesktopPetCore/OneShotPlaybackState.swift`
- `Sources/DesktopPetCore/PlaybackRevisionPolicy.swift`
- `Tests/DesktopPetTests/OneShotPlaybackStateTests.swift`
- `Tests/DesktopPetTests/PlaybackRevisionPolicyTests.swift`
