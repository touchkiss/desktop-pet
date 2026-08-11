public enum TeleportEffectStyle: String, CaseIterable, Sendable {
    /// Strange portal — warm gold rim, soft iris suction
    case portal
    /// Dock-like genie suck / expand
    case warp
    /// Ash dissolve / reassemble
    case particles
    /// Soft vertical light-beam transporter
    case beam
    /// Quick flash-step blink
    case blink
    /// Soft mist envelop / clear
    case mist
}

public enum TeleportLandingMode: String, Sendable {
    case corner
    case cursorNudge
}
