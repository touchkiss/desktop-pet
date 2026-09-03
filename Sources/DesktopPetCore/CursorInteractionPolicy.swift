import Foundation

public enum CursorInteractionPolicy {
    public static let minimumPreyDisplaySize = 16.0
    public static let maximumPreyDisplaySize = 128.0
    public static let defaultPreyDisplaySize = 48.0

    public static func clampedPreyDisplaySize(_ size: Double) -> Double {
        min(max(size, minimumPreyDisplaySize), maximumPreyDisplaySize)
    }

    public static func isInteractionEligible(
        isAutonomous: Bool,
        landingMode: TeleportLandingMode,
        hasPreyCandidate: Bool,
        hasInteractionCandidate: Bool
    ) -> Bool {
        isAutonomous
            && landingMode == .cursorNudge
            && hasPreyCandidate
            && hasInteractionCandidate
    }
}
