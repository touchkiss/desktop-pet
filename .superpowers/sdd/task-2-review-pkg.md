# Task 2 review package (post-fix)

## Diff TeleportMath.swift vs pre-task-2
--- /Users/liushiyou/Documents/macos/desktop-pet/.superpowers/sdd/snapshots/pre-task-2/TeleportMath.swift	2026-08-04 19:57:50
+++ /Users/liushiyou/Documents/macos/desktop-pet/Sources/DesktopPetCore/TeleportMath.swift	2026-08-04 20:08:47
@@ -43,3 +43,131 @@
         return clamp01(unitRandom) < 0.25 ? .cursorNudge : .corner
     }
 }
+
+public struct TeleportScreenBox: Equatable, Sendable {
+    public var visibleFrame: CGRect
+    public init(visibleFrame: CGRect) { self.visibleFrame = visibleFrame }
+}
+
+extension TeleportMath {
+    /// Four corner bands (~8%–20% of edges). Use 20% width/height squares at each corner.
+    public static func cornerRegions(in visibleFrame: CGRect) -> [CGRect] {
+        let w = visibleFrame.width * 0.20
+        let h = visibleFrame.height * 0.20
+        let f = visibleFrame
+        return [
+            CGRect(x: f.minX, y: f.maxY - h, width: w, height: h), // top-leading
+            CGRect(x: f.maxX - w, y: f.maxY - h, width: w, height: h), // top-trailing
+            CGRect(x: f.minX, y: f.minY, width: w, height: h), // bottom-leading
+            CGRect(x: f.maxX - w, y: f.minY, width: w, height: h) // bottom-trailing
+        ]
+    }
+
+    public static func clampOrigin(_ origin: CGPoint, petSize: CGSize, visibleFrame: CGRect) -> CGPoint {
+        let maxX = visibleFrame.maxX - petSize.width
+        let maxY = visibleFrame.maxY - petSize.height
+        return CGPoint(
+            x: min(max(origin.x, visibleFrame.minX), max(maxX, visibleFrame.minX)),
+            y: min(max(origin.y, visibleFrame.minY), max(maxY, visibleFrame.minY))
+        )
+    }
+
+    public static func randomOrigin(
+        in region: CGRect,
+        petSize: CGSize,
+        visibleFrame: CGRect,
+        unitRandomX: Double,
+        unitRandomY: Double
+    ) -> CGPoint {
+        let usable = CGRect(
+            x: region.minX,
+            y: region.minY,
+            width: max(0, region.width - petSize.width),
+            height: max(0, region.height - petSize.height)
+        )
+        let origin = CGPoint(
+            x: usable.minX + usable.width * CGFloat(clamp01(unitRandomX)),
+            y: usable.minY + usable.height * CGFloat(clamp01(unitRandomY))
+        )
+        return clampOrigin(origin, petSize: petSize, visibleFrame: visibleFrame)
+    }
+
+    public static func petCenter(origin: CGPoint, size: CGSize) -> CGPoint {
+        CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
+    }
+
+    public static func isFarEnough(from: CGPoint, to: CGPoint, petSize: CGSize) -> Bool {
+        let minDist = 1.5 * hypot(petSize.width, petSize.height)
+        let a = petCenter(origin: from, size: petSize)
+        let b = petCenter(origin: to, size: petSize)
+        return hypot(a.x - b.x, a.y - b.y) >= minDist
+    }
+
+    /// Ring radius lerp(120, 200, radiusUnit). Returns nil if center distance to cursor < 80 after clamp.
+    public static func cursorNudgeOrigin(
+        cursor: CGPoint,
+        petSize: CGSize,
+        visibleFrame: CGRect,
+        angleUnit: Double,
+        radiusUnit: Double
+    ) -> CGPoint? {
+        let angle = clamp01(angleUnit) * 2 * Double.pi
+        let radius = lerp(120, 200, radiusUnit)
+        let center = CGPoint(
+            x: cursor.x + CGFloat(cos(angle) * radius),
+            y: cursor.y + CGFloat(sin(angle) * radius)
+        )
+        let rawOrigin = CGPoint(x: center.x - petSize.width / 2, y: center.y - petSize.height / 2)
+        let origin = clampOrigin(rawOrigin, petSize: petSize, visibleFrame: visibleFrame)
+        let petC = petCenter(origin: origin, size: petSize)
+        let dist = hypot(petC.x - cursor.x, petC.y - cursor.y)
+        if dist < 80 { return nil }
+        return origin
+    }
+
+    public static func pickCornerOrigin(
+        screens: [TeleportScreenBox],
+        petSize: CGSize,
+        currentOrigin: CGPoint,
+        unitRandoms: [Double],
+        maxAttempts: Int = 12
+    ) -> CGPoint {
+        guard !screens.isEmpty else { return currentOrigin }
+        var best = clampOrigin(currentOrigin, petSize: petSize, visibleFrame: screens[0].visibleFrame)
+        let currentCenter = petCenter(origin: currentOrigin, size: petSize)
+        func centerDistance(to origin: CGPoint) -> CGFloat {
+            let c = petCenter(origin: origin, size: petSize)
+            return hypot(c.x - currentCenter.x, c.y - currentCenter.y)
+        }
+        var bestDistance = centerDistance(to: best)
+        var ri = 0
+        func next() -> Double {
+            defer { ri += 1 }
+            if ri < unitRandoms.count { return unitRandoms[ri] }
+            return 0.5
+        }
+        for _ in 0..<maxAttempts {
+            let screenIdx = min(screens.count - 1, Int(clamp01(next()) * Double(screens.count)))
+            let screen = screens[screenIdx]
+            let regions = cornerRegions(in: screen.visibleFrame)
+            let regionIdx = min(regions.count - 1, Int(clamp01(next()) * Double(regions.count)))
+            let region = regions[regionIdx]
+            let candidate = randomOrigin(
+                in: region,
+                petSize: petSize,
+                visibleFrame: screen.visibleFrame,
+                unitRandomX: next(),
+                unitRandomY: next()
+            )
+            let distance = centerDistance(to: candidate)
+            if distance > bestDistance {
+                best = candidate
+                bestDistance = distance
+            }
+            if isFarEnough(from: currentOrigin, to: candidate, petSize: petSize) {
+                return candidate
+            }
+        }
+        return best
+    }
+}

## Diff TeleportMathTests.swift vs pre-task-2
--- /Users/liushiyou/Documents/macos/desktop-pet/.superpowers/sdd/snapshots/pre-task-2/TeleportMathTests.swift	2026-08-04 19:57:50
+++ /Users/liushiyou/Documents/macos/desktop-pet/Tests/DesktopPetTests/TeleportMathTests.swift	2026-08-04 20:09:00
@@ -26,4 +26,170 @@
             XCTAssertLessThanOrEqual(v, base * 1.15)
         }
     }
+
+    func testCornerRegionsCountAndContainment() {
+        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
+        let regions = TeleportMath.cornerRegions(in: frame)
+        XCTAssertEqual(regions.count, 4)
+        for r in regions {
+            XCTAssertTrue(frame.contains(r))
+        }
+    }
+
+    func testRandomOriginKeepsPetInsideVisible() {
+        let visible = CGRect(x: 100, y: 50, width: 800, height: 600)
+        let region = CGRect(x: 100, y: 50, width: 160, height: 120)
+        let size = CGSize(width: 80, height: 80)
+        let origin = TeleportMath.randomOrigin(
+            in: region,
+            petSize: size,
+            visibleFrame: visible,
+            unitRandomX: 1,
+            unitRandomY: 1
+        )
+        let pet = CGRect(origin: origin, size: size)
+        XCTAssertTrue(visible.contains(pet))
+    }
+
+    func testFarEnoughUsesDiagonal() {
+        let size = CGSize(width: 100, height: 100)
+        let diagonal = hypot(100.0, 100.0)
+        let minDist = 1.5 * diagonal
+        XCTAssertFalse(TeleportMath.isFarEnough(
+            from: .zero,
+            to: CGPoint(x: minDist - 1, y: 0),
+            petSize: size
+        ))
+        XCTAssertTrue(TeleportMath.isFarEnough(
+            from: .zero,
+            to: CGPoint(x: minDist + 1, y: 0),
+            petSize: size
+        ))
+    }
+
+    func testCursorNudgeReturnsNilWhenTooCloseAfterClamp() {
+        // Tiny visible frame forces clamp onto cursor → nil (caller falls back to corner).
+        let visible = CGRect(x: 0, y: 0, width: 120, height: 120)
+        let pet = CGSize(width: 100, height: 100)
+        let cursor = CGPoint(x: 60, y: 60)
+        let result = TeleportMath.cursorNudgeOrigin(
+            cursor: cursor,
+            petSize: pet,
+            visibleFrame: visible,
+            angleUnit: 0,
+            radiusUnit: 0
+        )
+        XCTAssertNil(result)
+    }
+
+    func testCursorNudgeKeepsDistanceWhenRoomExists() {
+        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
+        let pet = CGSize(width: 80, height: 80)
+        let cursor = CGPoint(x: 1000, y: 600)
+        let origin = TeleportMath.cursorNudgeOrigin(
+            cursor: cursor,
+            petSize: pet,
+            visibleFrame: visible,
+            angleUnit: 0,
+            radiusUnit: 0.5
+        )
+        XCTAssertNotNil(origin)
+        let center = CGPoint(x: origin!.x + 40, y: origin!.y + 40)
+        let dist = hypot(center.x - cursor.x, center.y - cursor.y)
+        XCTAssertGreaterThanOrEqual(dist, 80)
+    }
+
+    func testPickCornerOriginReturnsFarEnoughCandidate() {
+        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
+        let screens = [TeleportScreenBox(visibleFrame: visible)]
+        let pet = CGSize(width: 80, height: 80)
+        let current = CGPoint(x: 100, y: 100)
+        // screen 0, region 3 (bottom-trailing), min corner
+        let result = TeleportMath.pickCornerOrigin(
+            screens: screens,
+            petSize: pet,
+            currentOrigin: current,
+            unitRandoms: [0, 0.75, 0, 0],
+            maxAttempts: 12
+        )
+        XCTAssertTrue(TeleportMath.isFarEnough(from: current, to: result, petSize: pet))
+    }
+
+    func testPickCornerOriginFallsBackToFarthestAfterMaxAttempts() {
+        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
+        let screens = [TeleportScreenBox(visibleFrame: visible)]
+        let pet = CGSize(width: 80, height: 80)
+        let current = CGPoint(x: 100, y: 650)
+        // Three attempts in top-leading region (index 0); none far enough.
+        let randoms: [Double] = [
+            0, 0, 0, 0,
+            0, 0, 1, 0,
+            0, 0, 0, 1
+        ]
+        let result = TeleportMath.pickCornerOrigin(
+            screens: screens,
+            petSize: pet,
+            currentOrigin: current,
+            unitRandoms: randoms,
+            maxAttempts: 3
+        )
+        XCTAssertFalse(TeleportMath.isFarEnough(from: current, to: result, petSize: pet))
+        let regions = TeleportMath.cornerRegions(in: visible)
+        let region = regions[0]
+        let candidates = [
+            TeleportMath.randomOrigin(in: region, petSize: pet, visibleFrame: visible, unitRandomX: 0, unitRandomY: 0),
+            TeleportMath.randomOrigin(in: region, petSize: pet, visibleFrame: visible, unitRandomX: 1, unitRandomY: 0),
+            TeleportMath.randomOrigin(in: region, petSize: pet, visibleFrame: visible, unitRandomX: 0, unitRandomY: 1)
+        ]
+        let currentCenter = TeleportMath.petCenter(origin: current, size: pet)
+        func dist(_ o: CGPoint) -> CGFloat {
+            let c = TeleportMath.petCenter(origin: o, size: pet)
+            return hypot(c.x - currentCenter.x, c.y - currentCenter.y)
+        }
+        let expected = candidates.max(by: { dist($0) < dist($1) })!
+        XCTAssertEqual(result.x, expected.x, accuracy: 0.001)
+        XCTAssertEqual(result.y, expected.y, accuracy: 0.001)
+    }
+
+    func testPickCornerOriginEmptyScreensReturnsCurrentOrigin() {
+        let pet = CGSize(width: 80, height: 80)
+        let current = CGPoint(x: 200, y: 300)
+        let result = TeleportMath.pickCornerOrigin(
+            screens: [],
+            petSize: pet,
+            currentOrigin: current,
+            unitRandoms: [0.5],
+            maxAttempts: 12
+        )
+        XCTAssertEqual(result, current)
+    }
+
+    func testPickCornerOriginUnitRandomOneSelectsLastIndex() {
+        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
+        let screens = [
+            TeleportScreenBox(visibleFrame: visible),
+            TeleportScreenBox(visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 800))
+        ]
+        let pet = CGSize(width: 80, height: 80)
+        let current = CGPoint(x: 5000, y: 5000)
+        // unitRandom 1.0 → last screen (index 1) and last region (index 3)
+        let result = TeleportMath.pickCornerOrigin(
+            screens: screens,
+            petSize: pet,
+            currentOrigin: current,
+            unitRandoms: [1, 1, 0, 0],
+            maxAttempts: 1
+        )
+        let secondScreen = screens[1].visibleFrame
+        let lastRegion = TeleportMath.cornerRegions(in: secondScreen)[3]
+        let expected = TeleportMath.randomOrigin(
+            in: lastRegion,
+            petSize: pet,
+            visibleFrame: secondScreen,
+            unitRandomX: 0,
+            unitRandomY: 0
+        )
+        XCTAssertEqual(result.x, expected.x, accuracy: 0.001)
+        XCTAssertEqual(result.y, expected.y, accuracy: 0.001)
+    }
 }
