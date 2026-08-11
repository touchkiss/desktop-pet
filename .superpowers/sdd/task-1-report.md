# Task 1 Report: DesktopPetCore — types + frequency math

## Status: DONE

## Summary

Created the `DesktopPetCore` SPM library target with teleport enums (`TeleportEffectStyle`, `TeleportLandingMode`) and frequency/scheduling math (`TeleportMath`). Wired `Package.swift` so `DesktopPet` executable and `DesktopPetTests` depend on `DesktopPetCore`. All 4 unit tests pass; app builds successfully.

## Files Changed

| Action | Path |
|--------|------|
| Modified | `Package.swift` |
| Created | `Sources/DesktopPetCore/TeleportTypes.swift` |
| Created | `Sources/DesktopPetCore/TeleportMath.swift` |
| Created | `Tests/DesktopPetTests/TeleportMathTests.swift` |

## TDD Evidence

### RED — Step 3 (tests before implementation)

**Command:**
```bash
cd /Users/liushiyou/Documents/macos/desktop-pet && swift test --filter TeleportMathTests
```

**Result:** Exit code 1 (expected failure)

**Output (abridged):**
```
error: 'desktop-pet': invalid custom path 'Sources/DesktopPetCore' for target 'DesktopPetCore'
```
(After creating empty `Sources/DesktopPetCore/` directory:)
```
error: /Users/liushiyou/Documents/macos/desktop-pet/Tests/DesktopPetTests/TeleportMathTests.swift:2:18 unable to resolve module dependency: 'DesktopPetCore'
error: Build failed
```

Confirms tests were written before `DesktopPetCore` module existed — compile failure as expected.

### GREEN — Step 5 (after implementation)

**Command:**
```bash
cd /Users/liushiyou/Documents/macos/desktop-pet && swift test --filter TeleportMathTests
```

**Result:** Exit code 0

**Output (abridged):**
```
Build complete! (33.76秒)
Test Suite 'TeleportMathTests' passed at 2026-08-04 19:55:04.210.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.005 (0.006) seconds
Test Suite 'Selected tests' passed at 2026-08-04 19:55:04.210.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.005 (0.010) seconds
```

Tests executed:
- `testDwellIntervalEndpoints` — PASS
- `testDwellIntervalClamps` — PASS
- `testHiddenDurationEndpoints` — PASS
- `testJitterStaysWithin15Percent` — PASS

### Build verification — Step 6

**Command:**
```bash
cd /Users/liushiyou/Documents/macos/desktop-pet && swift build
```

**Result:** Exit code 0 — build complete (DesktopPet links DesktopPetCore).

## Implementation Notes

- `dwellInterval` / `hiddenDuration` use `lerp` with `clamp01` on frequency, so out-of-range values (-1, 2) clamp to endpoints (60/12 and 2.0/0.6).
- `jitteredInterval` maps `unitRandom` ∈ [0,1] to factor ∈ [0.85, 1.15] via `0.85 + 0.30 * t`.
- `pickStyle`, `pickLandingMode`, and `scheduleDwell` implemented per spec but not covered by Task 1 tests (deferred to later tasks).

## Self-Review

| Check | Result |
|-------|--------|
| Package.swift matches brief verbatim | ✅ |
| Enums match spec (`portal`, `particles`, `warp`; `corner`, `cursorNudge`) | ✅ |
| Frequency math formulas match spec | ✅ |
| TDD order: failing tests → implementation → pass | ✅ |
| No git commands run | ✅ |
| Executable still builds | ✅ |

## Concerns

None. `CoreGraphics` is imported in `TeleportMath.swift` per brief (unused in Task 1; likely reserved for later geometry tasks).

## Commits

None (repo has no git per task overrides).
