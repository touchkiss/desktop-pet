import Foundation

/// Tunable chromakey parameters used for preview + final export.
struct ChromaKeySettings: Equatable, Sendable {
    /// Hex without `#`, e.g. `00C107`.
    var keyHex: String
    /// How aggressively green is treated as background. Higher = stronger key. Range ~0.05...0.55
    var similarity: Double
    /// Edge softness for border-connected green. Higher = softer fringe. Range ~0...0.4
    var blend: Double
    /// Green spill removal strength on subject edges. Range ~0...0.9
    var despillMix: Double

    static let `default` = ChromaKeySettings(
        keyHex: "00C107",
        similarity: 0.22,
        blend: 0.06,
        despillMix: 0.40
    )

    func clamped() -> ChromaKeySettings {
        ChromaKeySettings(
            keyHex: keyHex,
            similarity: min(0.55, max(0.04, similarity)),
            blend: min(0.40, max(0.0, blend)),
            despillMix: min(0.90, max(0.0, despillMix))
        )
    }

    /// Decode-only filter: extract RGBA frames; edge-connected key runs in Swift afterwards
    /// so subject interiors are never punched through.
    func decodeFilterGraph(workWidth: Int) -> String {
        [
            "format=rgba",
            "scale=\(workWidth):-1:flags=lanczos"
        ].joined(separator: ",")
    }
}

struct ImportStaging: Sendable {
    let clipID: String
    let displayName: String
    let localSourceURL: URL
    let clipDirectory: URL
    let duration: TimeInterval
}
