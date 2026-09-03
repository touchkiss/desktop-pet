# Task Group 4: Animated Cursor-Prey Overlay

Implement OpenSpec tasks 4.1–4.4.

## Requirements

- Create `Sources/DesktopPet/CursorPreyOverlayController.swift`, `@MainActor`, with a focused public-in-module interface:
  - failure callback for an active overlay
  - `start(clip: PetClip, settings: CursorPreySettings) -> Bool`
  - idempotent `stop()`
  - read-only active state useful to task-group-5 orchestration
- `start` must validate role, fps/frame count, first keyed PNG, and dimensions before hiding the pointer. If validation/window/first-frame setup fails, return false and leave the system pointer visible.
- Render a transparent borderless window above ordinary app windows, on all Spaces/full-screen auxiliary spaces, excluded from window cycling, and with `ignoresMouseEvents = true`; the real cursor remains the input hotspot.
- Size the overlay using the material's independently clamped 16–128 pt longest side and preserve source aspect ratio. Center the visual window on `NSEvent.mouseLocation` in global screen coordinates.
- Follow the cursor smoothly (up to 60 Hz) across displays and play the existing transparent PNG sequence at the clip's native fps, looping from the last frame to frame 1.
- Only after the first frame is visible may the controller call the balanced cursor-hide API and record hidden ownership. `stop()` may unhide only if this controller successfully hid it.
- A missing later frame, deleted frame directory, invalid display state, or timer failure must stop, release timers/cache/window, restore the pointer exactly once, then invoke the failure callback once. Do not invoke failure for an explicit normal `stop()`.
- Repeated `start` must safely stop the previous session first. Deinit/owner shutdown must restore the pointer.
- Keep cache bounded and release all frame references/timers/window on stop. No new dependency.

## TDD / Testability

- Before production overlay code, add a small pure frame/lifecycle helper in `DesktopPetCore` only if it materially improves deterministic coverage of frame looping or once-only failure/stop behavior. Run its focused test RED then GREEN.
- AppKit window, cursor, and multi-display behavior will be verified by build plus task-group-6 manual QA; do not add brittle GUI tests.

## Ownership

- Create `Sources/DesktopPet/CursorPreyOverlayController.swift`.
- Optionally create one focused helper in `Sources/DesktopPetCore/` and its test in `Tests/DesktopPetTests/`.
- Do not edit UI, model/store, PlaylistEngine, AppDelegate, TeleportController, README, or OpenSpec artifacts.
- Preserve all current edits; do not revert others. Do not commit.

## Verification

- Run any focused helper test RED/GREEN if added.
- Run `swift test`, `swift build`, and diff check.
- Self-review hide/unhide balance, repeated start/stop, timer invalidation, failure callback once, frame loop, cache bound, and multi-display global coordinates.

Write the full report to `.superpowers/sdd/cursor-prey-task-4-report.md`. Return status, one-line verification, and concerns.
