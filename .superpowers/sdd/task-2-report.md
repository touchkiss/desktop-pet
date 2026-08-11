# Task 2 Report: Landing Geometry Math

## Status
**COMPLETE** — All landing geometry helpers implemented per brief; TDD RED→GREEN verified.

## Changes

### `Sources/DesktopPetCore/TeleportMath.swift`
- Appended `TeleportScreenBox` struct (`visibleFrame: CGRect`, `Equatable`, `Sendable`).
- Appended extension with landing helpers:
  - `cornerRegions(in:)` — four 20% corner bands
  - `clampOrigin(_:petSize:visibleFrame:)`
  - `randomOrigin(in:petSize:visibleFrame:unitRandomX:unitRandomY:)`
  - `petCenter(origin:size:)`
  - `isFarEnough(from:to:petSize:)` — 1.5× diagonal threshold
  - `cursorNudgeOrigin(cursor:petSize:visibleFrame:angleUnit:radiusUnit:)` — ring lerp(120,200), nil if dist < 80
  - `pickCornerOrigin(screens:petSize:currentOrigin:unitRandoms:maxAttempts:)`
- Task 1 frequency/style APIs unchanged.

### `Tests/DesktopPetTests/TeleportMathTests.swift`
- Appended 5 landing tests from brief (corner regions, random origin, far-enough, cursor nudge nil/valid).

## TDD

| Phase | Result |
|-------|--------|
| RED (tests only) | Build failed — missing `cornerRegions`, `randomOrigin`, `isFarEnough`, `cursorNudgeOrigin` |
| GREEN (implementation) | All tests pass |

## Test Results

```
swift test --filter TeleportMathTests
Executed 9 tests, with 0 failures
```

- 4 Task 1 tests (dwell, hidden, jitter) — pass
- 5 Task 2 tests (landing geometry) — pass

## Self-Review

| Check | OK |
|-------|-----|
| Signatures match brief verbatim | ✓ |
| `TeleportScreenBox` in TeleportMath.swift | ✓ |
| Corner regions use 20% width/height at four corners | ✓ |
| `isFarEnough` uses pet centers + 1.5× hypot(w,h) | ✓ |
| `cursorNudgeOrigin` nil when clamped dist < 80 | ✓ |
| `pickCornerOrigin` with maxAttempts default 12 | ✓ |
| No Task 1 API removal | ✓ |

## Concerns

- **`pickCornerOrigin` untested** — brief lists implementation but no dedicated test; covered indirectly by design only.
- **Corner comment vs implementation** — doc says "~8%–20%" but code uses fixed 20%; matches brief code exactly.
- **`CGRect.contains`** — corner region test uses `frame.contains(r)`; regions on edges are contained (inclusive bounds on macOS).

## Commits
None (per override).

## Review Fixes (Task 2)

### Changes
- **`pickCornerOrigin`**: Tracks candidate with maximum center distance across attempts (true best-effort fallback); still returns early when `isFarEnough` passes.
- **Index selection**: Screen/region picks use `min(count - 1, Int(clamp01(u) * Double(count)))` — fixes bias at `unitRandom == 1.0` (no wrap to index 0).
- **Empty screens**: Replaced `precondition` with guard returning `currentOrigin` unchanged (no frame to clamp against).

### New tests
- `testPickCornerOriginReturnsFarEnoughCandidate`
- `testPickCornerOriginFallsBackToFarthestAfterMaxAttempts`
- `testPickCornerOriginEmptyScreensReturnsCurrentOrigin`
- `testPickCornerOriginUnitRandomOneSelectsLastIndex`

### Test Results

```
swift test --filter TeleportMathTests
Executed 13 tests, with 0 failures (0 unexpected) in 0.003 (0.006) seconds
```
