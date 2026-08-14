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

    /// Probability that a trip shows the travel streak — not every trip,
    /// so the "now you see me" surprise survives.
    public static let travelStreakChance = 0.5

    public static func shouldShowTravelStreak(unitRandom: Double) -> Bool {
        clamp01(unitRandom) < travelStreakChance
    }

    /// Styles the travel streak pairs well with. Wipe-style and in-place
    /// styles read as overkill with a bridge flying between the points.
    public static func styleSupportsStreak(_ style: TeleportEffectStyle) -> Bool {
        switch style {
        case .blink, .smear, .ink:
            return true
        case .particles, .beam, .pixel, .scanline, .develop, .swarm:
            return false
        }
    }

    /// Some styles come as a PAIR: if either end draws them, the whole trip
    /// uses them on both ends. Swarm is a single integrated journey; ink
    /// dissolves, an ink-wash bridge carries it, ink blooms back.
    public static func resolveStylePair(
        vanishDraw: TeleportEffectStyle,
        appearDraw: TeleportEffectStyle
    ) -> (vanish: TeleportEffectStyle, appear: TeleportEffectStyle) {
        if vanishDraw == .swarm || appearDraw == .swarm {
            return (.swarm, .swarm)
        }
        if vanishDraw == .ink || appearDraw == .ink {
            return (.ink, .ink)
        }
        return (vanishDraw, appearDraw)
    }

    /// Pick the bridge between the two ends. Whirlwind trips ride the
    /// twisting vortex; blink pairs favour shadow hops; move-style pairs
    /// draw from the whole family; wipe/in-place pairs go bridgeless.
    public static func pickTravelMiddle(
        vanishStyle: TeleportEffectStyle,
        appearStyle: TeleportEffectStyle,
        unitRandom: Double
    ) -> TravelMiddle {
        let r = clamp01(unitRandom)
        if vanishStyle == .swarm || appearStyle == .swarm {
            // The swarm IS its own bridge — never stack another one.
            return .none
        }
        if vanishStyle == .ink && appearStyle == .ink {
            // Ink rides ink: a wash-toned comet or twisting strands.
            if r < 0.5 { return .comet }
            return r < 0.8 ? .vortex : .shadowHops
        }
        if vanishStyle == .blink && appearStyle == .blink {
            if r < 0.55 { return .shadowHops }
            return r < 0.8 ? .comet : .vortex
        }
        if styleSupportsStreak(vanishStyle) && styleSupportsStreak(appearStyle) {
            if r < 0.35 { return .comet }
            if r < 0.6 { return .cloud }
            if r < 0.8 { return .vortex }
            return .shadowHops
        }
        return .none
    }

    /// Point at `fraction` (0…1) of the way along the polyline
    /// from → waypoints → to, measured by arc length.
    public static func pointAlongPolyline(
        from: CGPoint,
        to: CGPoint,
        waypoints: [CGPoint],
        fraction: Double
    ) -> CGPoint {
        let points = [from] + waypoints + [to]
        let total = travelPathLength(from: from, to: to, waypoints: waypoints)
        guard total > 0.001 else { return from }
        var remaining = clamp01(fraction) * total
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let segment = Double(hypot(b.x - a.x, b.y - a.y))
            if remaining <= segment || i == points.count - 2 {
                let t = segment > 0.001 ? CGFloat(min(1, remaining / segment)) : 0
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= segment
        }
        return to
    }

    /// Vanish and appear styles are picked independently; the streak only
    /// flies when BOTH ends can hand off to it.
    public static func streakAllowed(
        vanishStyle: TeleportEffectStyle,
        appearStyle: TeleportEffectStyle
    ) -> Bool {
        styleSupportsStreak(vanishStyle) && styleSupportsStreak(appearStyle)
    }

    /// Travel-streak flight time by path length (points): clamp(0.3, d/2400, 0.85).
    public static func travelDuration(distance: Double) -> Double {
        min(0.85, max(0.3, distance / 2400))
    }

    /// Intermediate waypoints for a WINDING streak: 1–3 turns that swing to
    /// alternating sides of the chord. Start/end are not included.
    /// Randoms consumed in order: turn count, starting side, then per turn
    /// (position jitter, amplitude).
    public static func travelWaypoints(
        from: CGPoint,
        to: CGPoint,
        unitRandoms: [Double]
    ) -> [CGPoint] {
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        let length = hypot(dx, dy)
        guard length > 1 else { return [] }
        var ri = 0
        func next() -> Double {
            defer { ri += 1 }
            return ri < unitRandoms.count ? clamp01(unitRandoms[ri]) : 0.5
        }
        let turns = 1 + Int(next() * 2.999)
        let nx = -dy / length
        let ny = dx / length
        var side: Double = next() < 0.5 ? 1 : -1
        var points: [CGPoint] = []
        for i in 1...turns {
            let baseT = Double(i) / Double(turns + 1)
            let t = min(0.92, max(0.08, baseT + (next() - 0.5) * 0.12))
            let amplitude = length * lerp(0.10, 0.22, next()) * side
            side = -side
            points.append(CGPoint(
                x: Double(from.x) + dx * t + nx * amplitude,
                y: Double(from.y) + dy * t + ny * amplitude
            ))
        }
        return points
    }

    /// Polyline length through the waypoints — feeds travelDuration so a
    /// winding flight takes proportionally longer than a straight one.
    public static func travelPathLength(
        from: CGPoint,
        to: CGPoint,
        waypoints: [CGPoint]
    ) -> Double {
        var total = 0.0
        var previous = from
        for point in waypoints + [to] {
            total += Double(hypot(point.x - previous.x, point.y - previous.y))
            previous = point
        }
        return total
    }

    /// Control point of the streak's quadratic bezier arc: perpendicular to
    /// the chord at its midpoint, offset lerp(0.12, 0.20, bulgeUnit) × chord
    /// length, on the side chosen by sideUnit (< 0.5 → left normal).
    public static func travelControlPoint(
        from: CGPoint,
        to: CGPoint,
        bulgeUnit: Double,
        sideUnit: Double
    ) -> CGPoint {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        let length = hypot(dx, dy)
        guard length > 0.001 else { return mid }
        let nx = -dy / length
        let ny = dx / length
        let side: Double = clamp01(sideUnit) < 0.5 ? 1 : -1
        let bulge = lerp(0.12, 0.20, bulgeUnit) * length * side
        return CGPoint(x: mid.x + CGFloat(nx * bulge), y: mid.y + CGFloat(ny * bulge))
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
