# Build verify — 2026-08-04

## `swift test --filter TeleportMathTests`

**Result: PASS** (exit 0)

```
Building for debugging...
[Planning deferred tasks]
[1 / 6] DesktopPetTests-product
[5 / 10] DesktopPet-product
[9 / 14] DesktopPet-product
[14 / 18] DesktopPet-product
[18 / 20] DesktopPet-product
Build complete! (2.56秒)
Test Suite 'Selected tests' started at 2026-08-04 20:40:49.162.
Test Suite 'DesktopPetTests.xctest' started at 2026-08-04 20:40:49.164.
Test Suite 'TeleportMathTests' started at 2026-08-04 20:40:49.164.
Test Case '-[DesktopPetTests.TeleportMathTests testCornerRegionsCountAndContainment]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testCornerRegionsCountAndContainment]' passed (0.002 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testCursorNudgeKeepsDistanceWhenRoomExists]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testCursorNudgeKeepsDistanceWhenRoomExists]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testCursorNudgeReturnsNilWhenTooCloseAfterClamp]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testCursorNudgeReturnsNilWhenTooCloseAfterClamp]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testDwellIntervalClamps]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testDwellIntervalClamps]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testDwellIntervalEndpoints]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testDwellIntervalEndpoints]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testFarEnoughUsesDiagonal]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testFarEnoughUsesDiagonal]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testHiddenDurationEndpoints]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testHiddenDurationEndpoints]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testJitterStaysWithin15Percent]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testJitterStaysWithin15Percent]' passed (0.001 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testPickCornerOriginEmptyScreensReturnsCurrentOrigin]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testPickCornerOriginEmptyScreensReturnsCurrentOrigin]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testPickCornerOriginFallsBackToFarthestAfterMaxAttempts]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testPickCornerOriginFallsBackToFarthestAfterMaxAttempts]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testPickCornerOriginReturnsFarEnoughCandidate]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testPickCornerOriginReturnsFarEnoughCandidate]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testPickCornerOriginUnitRandomOneSelectsLastIndex]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testPickCornerOriginUnitRandomOneSelectsLastIndex]' passed (0.000 seconds).
Test Case '-[DesktopPetTests.TeleportMathTests testRandomOriginKeepsPetInsideVisible]' started.
Test Case '-[DesktopPetTests.TeleportMathTests testRandomOriginKeepsPetInsideVisible]' passed (0.000 seconds).
Test Suite 'TeleportMathTests' passed at 2026-08-04 20:40:49.170.
	 Executed 13 tests, with 0 failures (0 unexpected) in 0.004 (0.006) seconds
Test Suite 'DesktopPetTests.xctest' passed at 2026-08-04 20:40:49.170.
	 Executed 13 tests, with 0 failures (0 unexpected) in 0.004 (0.006) seconds
Test Suite 'Selected tests' passed at 2026-08-04 20:40:49.170.
	 Executed 13 tests, with 0 failures (0 unexpected) in 0.004 (0.008) seconds
```

## `swift build`

**Result: PASS** (exit 0, first attempt; no AppDelegate retry needed)

```
Building for debugging...
Build complete! (0.23秒)
```

## Notes

- Initial sandboxed `swift test` failed with `sandbox-exec: sandbox_apply: Operation not permitted` on Package manifest; commands re-run with full permissions succeeded.
