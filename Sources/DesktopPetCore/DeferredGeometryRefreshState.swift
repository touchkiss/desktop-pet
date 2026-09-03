public struct DeferredGeometryRefreshState: Equatable, Sendable {
    public private(set) var isFrozen = false
    private var hasDeferredRefresh = false

    public init() {}

    public mutating func beginFreeze() {
        isFrozen = true
    }

    /// Returns true when the caller should refresh geometry immediately.
    @discardableResult
    public mutating func requestRefresh() -> Bool {
        guard isFrozen else { return true }
        hasDeferredRefresh = true
        return false
    }

    /// Returns true exactly once when a frozen refresh must now be applied.
    @discardableResult
    public mutating func endFreeze() -> Bool {
        guard isFrozen else { return false }
        isFrozen = false
        let shouldRefresh = hasDeferredRefresh
        hasDeferredRefresh = false
        return shouldRefresh
    }
}
