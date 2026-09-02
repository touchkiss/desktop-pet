import Foundation

public enum IdlePresentationPhase: Equatable, Sendable {
    case normal
    case manic
}

public enum IdlePresentationPolicy {
    public static let supportedIdleDelays: [TimeInterval] = [60, 180, 300, 600, 900, 1800]
    public static let defaultIdleDelay: TimeInterval = 300
    public static let minimumManicScale = 1.0
    public static let maximumManicScale = 3.0
    public static let defaultManicScale = 2.0

    public static func resolvedIdleDelay(
        storedValue: TimeInterval?,
        keyWasPresent: Bool
    ) -> TimeInterval? {
        guard keyWasPresent else { return defaultIdleDelay }
        guard let storedValue else { return nil }
        return supportedIdleDelays.contains(storedValue) ? storedValue : defaultIdleDelay
    }

    public static func clampedManicScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return defaultManicScale }
        return min(maximumManicScale, max(minimumManicScale, scale))
    }

    public static func resolvedManicScale(_ storedValue: Double?) -> Double {
        clampedManicScale(storedValue ?? defaultManicScale)
    }

    public static func phase(
        idleSeconds: TimeInterval,
        delay: TimeInterval?
    ) -> IdlePresentationPhase {
        guard idleSeconds.isFinite, idleSeconds >= 0, let delay else { return .normal }
        return idleSeconds >= delay ? .manic : .normal
    }

    public static func presentationMultiplier(
        manicScale: Double,
        phase: IdlePresentationPhase
    ) -> Double {
        phase == .manic ? clampedManicScale(manicScale) : 1
    }
}
