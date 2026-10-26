/// System and display power notifications may overlap and arrive more than once.
public struct PlaybackSuspensionState {
    public enum Reason: Hashable { case system, display }
    private var reasons: Set<Reason> = []
    public var isSuspended: Bool { !reasons.isEmpty }

    public init() {}

    /// Returns true only when the aggregate playback permission changes.
    @discardableResult
    public mutating func setSleeping(_ sleeping: Bool, reason: Reason) -> Bool {
        let previous = isSuspended
        if sleeping { reasons.insert(reason) } else { reasons.remove(reason) }
        return previous != isSuspended
    }
}
