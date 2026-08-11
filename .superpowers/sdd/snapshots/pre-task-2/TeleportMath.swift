import Foundation
import CoreGraphics

public enum TeleportMath {
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
