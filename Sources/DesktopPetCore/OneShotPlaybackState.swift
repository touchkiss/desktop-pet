import Foundation

/// Pure state for a special clip that must play once before ordinary playback resumes.
public struct OneShotPlaybackState: Equatable {
    public enum Resolution: Equatable {
        case play(String)
        case stop
    }

    public private(set) var interactionID: String?
    public private(set) var preferredReturnID: String?

    public var isActive: Bool {
        interactionID != nil
    }

    public init() {}

    public mutating func start(interactionID: String, preferredReturnID: String?) {
        self.interactionID = interactionID
        self.preferredReturnID = preferredReturnID
    }

    /// Clears an active one-shot and identifies it exactly once for callers
    /// that need to deliver an abnormal-termination notification.
    @discardableResult
    public mutating func cancel() -> String? {
        guard let cancelledID = interactionID else { return nil }
        interactionID = nil
        preferredReturnID = nil
        return cancelledID
    }

    /// Resolves an active one-shot exactly once against the current ordinary playlist.
    public mutating func finish(availableOrdinaryIDs: [String]) -> Resolution? {
        guard isActive else { return nil }
        let preferredReturnID = preferredReturnID
        cancel()

        if let preferredReturnID, availableOrdinaryIDs.contains(preferredReturnID) {
            return .play(preferredReturnID)
        }
        if let fallbackID = availableOrdinaryIDs.first {
            return .play(fallbackID)
        }
        return .stop
    }

    /// A completion callback may synchronously start any new playback session,
    /// including one for the same clip. That newer session must win.
    public static func shouldApplyCompletionResolution(
        completionRevision: UInt,
        currentPlaybackRevision: UInt
    ) -> Bool {
        PlaybackRevisionPolicy.shouldAccept(
            expected: completionRevision,
            current: currentPlaybackRevision
        )
    }
}
