### Task 2: Landing geometry math

**Files:**
- Modify: `Sources/DesktopPetCore/TeleportMath.swift`
- Modify: `Tests/DesktopPetTests/TeleportMathTests.swift`

**Interfaces:**
- Consumes: `TeleportMath` from Task 1
- Produces:
  - `struct TeleportScreenBox: Equatable` — `visibleFrame: CGRect`
  - `static func cornerRegions(in visibleFrame: CGRect) -> [CGRect]`
  - `static func randomOrigin(in region: CGRect, petSize: CGSize, visibleFrame: CGRect, unitRandomX: Double, unitRandomY: Double) -> CGPoint`
  - `static func isFarEnough(from: CGPoint, to: CGPoint, petSize: CGSize) -> Bool`
  - `static func cursorNudgeOrigin(cursor: CGPoint, petSize: CGSize, visibleFrame: CGRect, angleUnit: Double, radiusUnit: Double) -> CGPoint?`
  - `static func pickCornerOrigin(screens: [TeleportScreenBox], petSize: CGSize, currentOrigin: CGPoint, unitRandoms: [Double], maxAttempts: Int) -> CGPoint`

- [ ] **Step 1: Write failing landing tests**

Append to `TeleportMathTests.swift`:

```swift
    func testCornerRegionsCountAndContainment() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let regions = TeleportMath.cornerRegions(in: frame)
        XCTAssertEqual(regions.count, 4)
        for r in regions {
            XCTAssertTrue(frame.contains(r))
        }
    }

    func testRandomOriginKeepsPetInsideVisible() {
        let visible = CGRect(x: 100, y: 50, width: 800, height: 600)
        let region = CGRect(x: 100, y: 50, width: 160, height: 120)
        let size = CGSize(width: 80, height: 80)
        let origin = TeleportMath.randomOrigin(
            in: region,
            petSize: size,
            visibleFrame: visible,
            unitRandomX: 1,
            unitRandomY: 1
        )
        let pet = CGRect(origin: origin, size: size)
        XCTAssertTrue(visible.contains(pet))
    }

    func testFarEnoughUsesDiagonal() {
        let size = CGSize(width: 100, height: 100)
        let diagonal = hypot(100.0, 100.0)
        let minDist = 1.5 * diagonal
        XCTAssertFalse(TeleportMath.isFarEnough(
            from: .zero,
            to: CGPoint(x: minDist - 1, y: 0),
            petSize: size
        ))
        XCTAssertTrue(TeleportMath.isFarEnough(
            from: .zero,
            to: CGPoint(x: minDist + 1, y: 0),
            petSize: size
        ))
    }

    func testCursorNudgeReturnsNilWhenTooCloseAfterClamp() {
        // Tiny visible frame forces clamp onto cursor → nil (caller falls back to corner).
        let visible = CGRect(x: 0, y: 0, width: 120, height: 120)
        let pet = CGSize(width: 100, height: 100)
        let cursor = CGPoint(x: 60, y: 60)
        let result = TeleportMath.cursorNudgeOrigin(
            cursor: cursor,
            petSize: pet,
            visibleFrame: visible,
            angleUnit: 0,
            radiusUnit: 0
        )
        XCTAssertNil(result)
    }

    func testCursorNudgeKeepsDistanceWhenRoomExists() {
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let pet = CGSize(width: 80, height: 80)
        let cursor = CGPoint(x: 1000, y: 600)
        let origin = TeleportMath.cursorNudgeOrigin(
            cursor: cursor,
            petSize: pet,
            visibleFrame: visible,
            angleUnit: 0,
            radiusUnit: 0.5
        )
        XCTAssertNotNil(origin)
        let center = CGPoint(x: origin!.x + 40, y: origin!.y + 40)
        let dist = hypot(center.x - cursor.x, center.y - cursor.y)
        XCTAssertGreaterThanOrEqual(dist, 80)
    }
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `swift test --filter TeleportMathTests`

Expected: missing landing symbols

- [ ] **Step 3: Implement landing helpers**

Append to `TeleportMath.swift`:

```swift
public struct TeleportScreenBox: Equatable, Sendable {
    public var visibleFrame: CGRect
    public init(visibleFrame: CGRect) { self.visibleFrame = visibleFrame }
}

extension TeleportMath {
    /// Four corner bands (~8%–20% of edges). Use 20% width/height squares at each corner.
    public static func cornerRegions(in visibleFrame: CGRect) -> [CGRect] {
        let w = visibleFrame.width * 0.20
        let h = visibleFrame.height * 0.20
        let f = visibleFrame
        return [
            CGRect(x: f.minX, y: f.maxY - h, width: w, height: h), // top-leading
            CGRect(x: f.maxX - w, y: f.maxY - h, width: w, height: h), // top-trailing
            CGRect(x: f.minX, y: f.minY, width: w, height: h), // bottom-leading
            CGRect(x: f.maxX - w, y: f.minY, width: w, height: h) // bottom-trailing
        ]
    }

    public static func clampOrigin(_ origin: CGPoint, petSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let maxX = visibleFrame.maxX - petSize.width
        let maxY = visibleFrame.maxY - petSize.height
        return CGPoint(
            x: min(max(origin.x, visibleFrame.minX), max(maxX, visibleFrame.minX)),
            y: min(max(origin.y, visibleFrame.minY), max(maxY, visibleFrame.minY))
        )
    }

    public static func randomOrigin(
        in region: CGRect,
        petSize: CGSize,
        visibleFrame: CGRect,
        unitRandomX: Double,
        unitRandomY: Double
    ) -> CGPoint {
        let usable = CGRect(
            x: region.minX,
            y: region.minY,
            width: max(0, region.width - petSize.width),
            height: max(0, region.height - petSize.height)
        )
        let origin = CGPoint(
            x: usable.minX + usable.width * CGFloat(clamp01(unitRandomX)),
            y: usable.minY + usable.height * CGFloat(clamp01(unitRandomY))
        )
        return clampOrigin(origin, petSize: petSize, visibleFrame: visibleFrame)
    }

    public static func petCenter(origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    public static func isFarEnough(from: CGPoint, to: CGPoint, petSize: CGSize) -> Bool {
        let minDist = 1.5 * hypot(petSize.width, petSize.height)
        let a = petCenter(origin: from, size: petSize)
        let b = petCenter(origin: to, size: petSize)
        return hypot(a.x - b.x, a.y - b.y) >= minDist
    }

    /// Ring radius lerp(120, 200, radiusUnit). Returns nil if center distance to cursor < 80 after clamp.
    public static func cursorNudgeOrigin(
        cursor: CGPoint,
        petSize: CGSize,
        visibleFrame: CGRect,
        angleUnit: Double,
        radiusUnit: Double
    ) -> CGPoint? {
        let angle = clamp01(angleUnit) * 2 * Double.pi
        let radius = lerp(120, 200, radiusUnit)
        let center = CGPoint(
            x: cursor.x + CGFloat(cos(angle) * radius),
            y: cursor.y + CGFloat(sin(angle) * radius)
        )
        let rawOrigin = CGPoint(x: center.x - petSize.width / 2, y: center.y - petSize.height / 2)
        let origin = clampOrigin(rawOrigin, petSize: petSize, visibleFrame: visibleFrame)
        let petC = petCenter(origin: origin, size: petSize)
        let dist = hypot(petC.x - cursor.x, petC.y - cursor.y)
        if dist < 80 { return nil }
        return origin
    }

    public static func pickCornerOrigin(
        screens: [TeleportScreenBox],
        petSize: CGSize,
        currentOrigin: CGPoint,
        unitRandoms: [Double],
        maxAttempts: Int = 12
    ) -> CGPoint {
        precondition(!screens.isEmpty)
        var best = clampOrigin(currentOrigin, petSize: petSize, visibleFrame: screens[0].visibleFrame)
        var ri = 0
        func next() -> Double {
            defer { ri += 1 }
            if ri < unitRandoms.count { return unitRandoms[ri] }
            return 0.5
        }
        for _ in 0..<maxAttempts {
            let screen = screens[Int(clamp01(next()) * Double(screens.count)) % screens.count]
            let regions = cornerRegions(in: screen.visibleFrame)
            let region = regions[Int(clamp01(next()) * Double(regions.count)) % regions.count]
            let candidate = randomOrigin(
                in: region,
                petSize: petSize,
                visibleFrame: screen.visibleFrame,
                unitRandomX: next(),
                unitRandomY: next()
            )
            best = candidate
            if isFarEnough(from: currentOrigin, to: candidate, petSize: petSize) {
                return candidate
            }
        }
        return best
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `swift test --filter TeleportMathTests`

Expected: PASS (adjust `testCursorNudgeReturnsNilWhenTooCloseAfterClamp` geometry if a false positive appears — keep the <80 rule)

---

