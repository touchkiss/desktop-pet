import Foundation
import CoreGraphics

public enum TeleportMath {
    public static let defaultReminderMessages = [
        "喝点水吧",
        "站起来走走",
        "看看远处放松一下"
    ]

    public static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * clamp01(t)
    }

    /// Visible dwell before next vanish. Spec: lerp(60, 12, f).
    public static func dwellInterval(frequency: Double) -> Double {
        lerp(60, 12, frequency)
    }

    /// Hidden pause. Spec: lerp(2.0, 0.6, f).
    public static func hiddenDuration(frequency: Double) -> Double {
        lerp(2.0, 0.6, frequency)
    }

    /// `unitRandom` in 0...1 → ±15% around base.
    public static func jitteredInterval(base: Double, unitRandom: Double) -> Double {
        let t = clamp01(unitRandom)
        let factor = 0.85 + 0.30 * t
        return base * factor
    }

    public static func scheduleDwell(frequency: Double, unitRandom: Double) -> Double {
        jitteredInterval(base: dwellInterval(frequency: frequency), unitRandom: unitRandom)
    }

    /// Probability of teleporting when a clip finishes. Spec remap: lerp(0.25, 1.0, f).
    public static func clipEndTeleportChance(frequency: Double) -> Double {
        lerp(0.25, 1.0, frequency)
    }

    public static func shouldTeleportAtClipEnd(frequency: Double, unitRandom: Double) -> Bool {
        clamp01(unitRandom) < clipEndTeleportChance(frequency: frequency)
    }

    public static func pickStyle(unitRandom: Double) -> TeleportEffectStyle {
        let styles = TeleportEffectStyle.allCases
        let idx = min(styles.count - 1, Int(clamp01(unitRandom) * Double(styles.count)))
        return styles[idx]
    }

    /// When nudgeEnabled, probability 1/4 → cursorNudge.
    public static func pickLandingMode(nudgeEnabled: Bool, unitRandom: Double) -> TeleportLandingMode {
        guard nudgeEnabled else { return .corner }
        return clamp01(unitRandom) < 0.25 ? .cursorNudge : .corner
    }
}

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
        guard !screens.isEmpty else { return currentOrigin }
        var best = clampOrigin(currentOrigin, petSize: petSize, visibleFrame: screens[0].visibleFrame)
        let currentCenter = petCenter(origin: currentOrigin, size: petSize)
        func centerDistance(to origin: CGPoint) -> CGFloat {
            let c = petCenter(origin: origin, size: petSize)
            return hypot(c.x - currentCenter.x, c.y - currentCenter.y)
        }
        var bestDistance = centerDistance(to: best)
        var ri = 0
        func next() -> Double {
            defer { ri += 1 }
            if ri < unitRandoms.count { return unitRandoms[ri] }
            return 0.5
        }
        for _ in 0..<maxAttempts {
            let screenIdx = min(screens.count - 1, Int(clamp01(next()) * Double(screens.count)))
            let screen = screens[screenIdx]
            let regions = cornerRegions(in: screen.visibleFrame)
            let regionIdx = min(regions.count - 1, Int(clamp01(next()) * Double(regions.count)))
            let region = regions[regionIdx]
            let candidate = randomOrigin(
                in: region,
                petSize: petSize,
                visibleFrame: screen.visibleFrame,
                unitRandomX: next(),
                unitRandomY: next()
            )
            let distance = centerDistance(to: candidate)
            if distance > bestDistance {
                best = candidate
                bestDistance = distance
            }
            if isFarEnough(from: currentOrigin, to: candidate, petSize: petSize) {
                return candidate
            }
        }
        return best
    }
}
