# Reduce Teleport Interruption Probabilities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce autonomous cursor-near landings and clip-end teleports to 20% of their current probabilities.

**Architecture:** Keep both decisions in the existing deterministic `TeleportMath` policy. Change only probability constants and endpoint expectations; callers, saved slider values, and UI controls remain unchanged.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest.

## Global Constraints

- Target macOS 13 and later.
- Cursor-near landing probability changes from `25%` to exactly `5%` when enabled.
- Clip-end teleport probability remains linear in `teleportFrequency`, changing from `25%–100%` to exactly `5%–20%`.
- Existing `teleportFrequency` values remain stored in `0...1` without migration.
- Explicit summons, timing, landing geometry, and animation behavior do not change.

---

### Task 1: Reduce Both Autonomous Teleport Probabilities

**Files:**
- Modify: `Tests/DesktopPetTests/TeleportMathTests.swift:30-35`
- Modify: `Sources/DesktopPetCore/TeleportMath.swift:40-58`

**Interfaces:**
- Preserves: `TeleportMath.clipEndTeleportChance(frequency:) -> Double`.
- Preserves: `TeleportMath.shouldTeleportAtClipEnd(frequency:unitRandom:) -> Bool`.
- Preserves: `TeleportMath.pickLandingMode(nudgeEnabled:unitRandom:) -> TeleportLandingMode`.

- [ ] **Step 1: Replace the old endpoint test with failing reduced-probability tests**

```swift
func testClipEndTeleportChanceEndpoints() {
    XCTAssertEqual(TeleportMath.clipEndTeleportChance(frequency: 0), 0.05, accuracy: 0.001)
    XCTAssertEqual(TeleportMath.clipEndTeleportChance(frequency: 1), 0.20, accuracy: 0.001)
    XCTAssertTrue(TeleportMath.shouldTeleportAtClipEnd(frequency: 1, unitRandom: 0.199))
    XCTAssertFalse(TeleportMath.shouldTeleportAtClipEnd(frequency: 1, unitRandom: 0.20))
    XCTAssertFalse(TeleportMath.shouldTeleportAtClipEnd(frequency: 0, unitRandom: 0.05))
}

func testCursorNudgeLandingChanceIsFivePercent() {
    XCTAssertEqual(
        TeleportMath.pickLandingMode(nudgeEnabled: true, unitRandom: 0.049),
        .cursorNudge
    )
    XCTAssertEqual(
        TeleportMath.pickLandingMode(nudgeEnabled: true, unitRandom: 0.05),
        .corner
    )
    XCTAssertEqual(
        TeleportMath.pickLandingMode(nudgeEnabled: false, unitRandom: 0),
        .corner
    )
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter TeleportMathTests/testClipEndTeleportChanceEndpoints`

Expected: FAIL because the implementation still returns `0.25` and `1.0`.

Run: `swift test --filter TeleportMathTests/testCursorNudgeLandingChanceIsFivePercent`

Expected: FAIL because `unitRandom: 0.05` still selects `.cursorNudge` under the old `0.25` threshold.

- [ ] **Step 3: Implement the reduced constants**

```swift
/// Probability of teleporting when a clip finishes: lerp(0.05, 0.20, f).
public static func clipEndTeleportChance(frequency: Double) -> Double {
    lerp(0.05, 0.20, frequency)
}

/// When nudgeEnabled, probability 1/20 → cursorNudge.
public static func pickLandingMode(nudgeEnabled: Bool, unitRandom: Double) -> TeleportLandingMode {
    guard nudgeEnabled else { return .corner }
    return clamp01(unitRandom) < 0.05 ? .cursorNudge : .corner
}
```

- [ ] **Step 4: Run focused and full verification**

Run: `swift test --filter TeleportMathTests`

Expected: all `TeleportMathTests` pass.

Run: `swift test`

Expected: all project tests pass.

Run: `swift build`

Expected: debug build succeeds without warnings.

- [ ] **Step 5: Check and commit only this isolated change**

Run: `git diff --check -- Sources/DesktopPetCore/TeleportMath.swift Tests/DesktopPetTests/TeleportMathTests.swift docs/superpowers/plans/2026-08-28-reduce-teleport-interruption-probabilities.md`

Expected: no whitespace errors.

```bash
git add Sources/DesktopPetCore/TeleportMath.swift Tests/DesktopPetTests/TeleportMathTests.swift docs/superpowers/plans/2026-08-28-reduce-teleport-interruption-probabilities.md
git commit -m "[传送] 降低自主传送触发概率"
```
