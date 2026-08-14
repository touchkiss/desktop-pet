public enum TeleportEffectStyle: String, CaseIterable, Sendable {
    /// Ash dissolve / reassemble (noise wipe)
    case particles
    /// CRT switch-off / switch-on
    case beam
    /// Quick flash-step blink
    case blink
    /// Mosaic tiles crumble away / fly back together
    case pixel
    /// 拉丝瞬移 — motion-blur smear along the travel direction
    case smear
    /// 扫描线重组 — a bright scanline erases / prints the cat
    case scanline
    /// 墨滴晕染 — ink bloom: desaturate, blur, crumble-edged blot
    case ink
    /// 老照片显影 — Polaroid develop / wash out
    case develop
    /// 像素洪流 — tiles shatter, funnel into one thin light stream, and
    /// reassemble at the destination (integrated whole-trip effect)
    case swarm
}

/// What bridges the hidden gap between vanish and appear.
public enum TravelMiddle: String, CaseIterable, Sendable {
    /// No bridge — classic silent reappearance.
    case none
    /// Single winding comet with braided side wisps.
    case comet
    /// 筋斗云 — a small cloud carries the cat's likeness across.
    case cloud
    /// 妖风缠绕 — several strands of light twisting around each other.
    case vortex
    /// 残影连跳 — white silhouettes flash along the route, hop by hop.
    case shadowHops
}

public enum TeleportLandingMode: String, Sendable {
    case corner
    case cursorNudge
}
