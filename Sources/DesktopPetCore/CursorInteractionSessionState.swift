import Foundation

/// Pure lifecycle state for one paired cursor-prey interaction.
public struct CursorInteractionSessionState: Equatable {
    public enum Phase: Equatable {
        case idle
        case pending
        case active
    }

    public enum Cleanup: Equatable {
        case pending
        case active
    }

    public private(set) var phase: Phase = .idle
    public private(set) var preyID: String?
    public private(set) var interactionID: String?

    public init() {}

    /// Saves one distinct pair without replacing an existing session.
    @discardableResult
    public mutating func prepare(preyID: String, interactionID: String) -> Bool {
        guard phase == .idle,
              preyID != interactionID else {
            return false
        }

        self.preyID = preyID
        self.interactionID = interactionID
        phase = .pending
        return true
    }

    /// Marks a prepared pair active exactly once.
    @discardableResult
    public mutating func activate() -> Bool {
        guard phase == .pending,
              preyID != nil,
              interactionID != nil else {
            return false
        }
        phase = .active
        return true
    }

    /// True when a render failure belongs to this prepared interaction and
    /// the playback engine still identifies it as the active one-shot clip.
    public func shouldCancelForFrameFailure(
        clipID: String,
        currentClipID: String?,
        isPlayingOneShot: Bool
    ) -> Bool {
        phase != .idle
            && isPlayingOneShot
            && interactionID == clipID
            && currentClipID == clipID
    }

    /// Clears the session and reports its former phase exactly once.
    @discardableResult
    public mutating func clear() -> Cleanup? {
        let cleanup: Cleanup
        switch phase {
        case .idle:
            return nil
        case .pending:
            cleanup = .pending
        case .active:
            cleanup = .active
        }

        phase = .idle
        preyID = nil
        interactionID = nil
        return cleanup
    }
}
