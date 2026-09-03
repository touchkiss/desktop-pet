import Foundation

/// Pure lifecycle for foreground-assisted cursor hiding. The cursor is only
/// marked hidden after the application has actually become active.
public struct CursorVisibilityLeaseState: Equatable {
    public enum Action: Equatable {
        case requestForeground
        case hideCursor
        case restorePreviousApplication
        case showCursor
    }

    private enum Phase: Equatable {
        case idle
        case requestingForeground
        case foregroundAcquired
        case cursorHidden
    }

    private var phase: Phase = .idle
    public var isActive: Bool { phase != .idle }

    public init() {}

    public mutating func start() -> Action? {
        guard phase == .idle else { return nil }
        phase = .requestingForeground
        return .requestForeground
    }

    public mutating func didBecomeActive() -> Action? {
        guard phase == .requestingForeground else { return nil }
        phase = .foregroundAcquired
        return .hideCursor
    }

    public mutating func didHideCursor() -> Action? {
        guard phase == .foregroundAcquired else { return nil }
        phase = .cursorHidden
        return .restorePreviousApplication
    }

    public mutating func stop() -> Action? {
        let shouldShow = phase == .cursorHidden
        phase = .idle
        return shouldShow ? .showCursor : nil
    }
}
