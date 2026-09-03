# Cursor-Prey Task Group 4 Report

## Result

DONE

Implemented OpenSpec tasks 4.1–4.4 with a main-actor cursor-prey overlay and a small deterministic frame-loop helper.

## Files owned and changed

- `Sources/DesktopPet/CursorPreyOverlayController.swift`
  - Transparent, borderless, click-through floating overlay window that joins all Spaces and full-screen auxiliary spaces and is excluded from window cycling.
  - Validates cursor-prey role, frame count/fps, declared dimensions, first keyed PNG, first image dimensions, initial global cursor display, and first-frame visibility before hiding the cursor.
  - Uses one health-checked 60 Hz driver timer. Monotonic elapsed time advances frames at the native fps, retaining fractional frame time and deterministically skipping/wrapping after delayed ticks; revision gating prevents a stopped/replaced session from affecting a newer one.
  - Sizes to the independently clamped material setting while preserving declared source aspect ratio; positions in global `NSEvent.mouseLocation` coordinates.
  - Uses a bounded FIFO 24-image cache, checks frame-file existence even for cached images, and treats missing frames, deleted frame directories, invalid display state, invalid driver state, or an ordered-out/closed/hidden window as a once-only active-overlay failure. A window-close delegate callback reports closure immediately.
  - `stop()` is idempotent, invalidates/release timers and UI/cache resources, and balances `NSCursor.hide()` only if this controller successfully hid the pointer. Isolated deinit performs the same cleanup.
- `Sources/DesktopPetCore/CursorPreyPlaybackState.swift`
  - Pure state helper for frame-1 startup, last-to-first looping, native-fps elapsed-time advancement with retained fractional time, invalid sequence rejection, and idempotent stop.
- `Tests/DesktopPetTests/CursorPreyPlaybackStateTests.swift`
  - Covers loop wrap, elapsed-time multi-step/wrap, fractional elapsed-time carry, stop/restart harmlessness, and empty sequence rejection.

## TDD evidence

1. RED: `swift test --filter CursorPreyPlaybackStateTests` failed as expected because `CursorPreyPlaybackState` did not yet exist.
2. GREEN: the same focused command passed with 3 tests after the helper implementation.

## Final verification

- `swift test` — passed: 41 tests, 0 failures.
- `swift build` — passed with no compiler warnings.
- `git diff --check -- Sources/DesktopPet/CursorPreyOverlayController.swift Sources/DesktopPetCore/CursorPreyPlaybackState.swift Tests/DesktopPetTests/CursorPreyPlaybackStateTests.swift` — passed.

## Self-review

- Pointer hiding occurs only after first-frame visibility and uses owned, balanced hide/unhide state.
- Explicit/repeated stop does not invoke the failure callback; failure stops first and then calls it once.
- Replacing a session invalidates timers and revision-gates queued callbacks.
- Frame state wraps last → first, cache is bounded, and all references are cleared on stop.
- Cursor placement uses global screen coordinates and rejects invalid display state.

## Lifecycle review-fix evidence

1. RED: after adding elapsed-time multi-step/wrap and fractional-carry tests, `swift test --filter CursorPreyPlaybackStateTests` failed as expected because the helper had no elapsed-time API.
2. GREEN: the focused command passed with 5 tests after the state helper and single-driver implementation.
3. Final verification after the review fixes:
   - `swift test` — passed: 43 tests, 0 failures.
   - `swift build` — passed with no compiler warnings.
   - `git diff --check -- Sources/DesktopPet/CursorPreyOverlayController.swift Sources/DesktopPetCore/CursorPreyPlaybackState.swift Tests/DesktopPetTests/CursorPreyPlaybackStateTests.swift` — passed.

## Concerns

No automated GUI coverage was added by design; visual multi-display/cursor-hide behavior remains for task-group-6 manual QA.
