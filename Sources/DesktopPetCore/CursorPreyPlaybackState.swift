import Foundation

/// Deterministic loop state for a cursor-prey PNG sequence.
public struct CursorPreyPlaybackState: Equatable {
    public private(set) var currentFrame: Int?
    private var frameCount = 0
    private var pendingFrameTime = 0.0

    public init() {}

    /// Starts at frame 1. Invalid sequences leave the state stopped.
    @discardableResult
    public mutating func start(frameCount: Int) -> Bool {
        stop()
        guard frameCount > 0 else { return false }

        self.frameCount = frameCount
        currentFrame = 1
        return true
    }

    /// Advances one frame, wrapping from the last frame to frame 1.
    @discardableResult
    public mutating func advance() -> Int? {
        advance(by: 1)
    }

    /// Advances according to monotonic elapsed time at the sequence's native
    /// frame rate. Fractional frame time is retained for the next driver tick.
    @discardableResult
    public mutating func advance(elapsed: TimeInterval, fps: Double) -> Int? {
        guard currentFrame != nil,
              frameCount > 0,
              elapsed.isFinite,
              elapsed > 0,
              fps.isFinite,
              fps > 0 else {
            return nil
        }

        let pendingFrames = pendingFrameTime + elapsed * fps
        guard pendingFrames.isFinite, pendingFrames >= 0,
              pendingFrames < Double(Int.max) else {
            return nil
        }

        let wholeFrames = Int(pendingFrames.rounded(.down))
        pendingFrameTime = pendingFrames - Double(wholeFrames)
        guard wholeFrames > 0 else { return currentFrame }
        return advance(by: wholeFrames)
    }

    public mutating func stop() {
        currentFrame = nil
        frameCount = 0
        pendingFrameTime = 0
    }

    private mutating func advance(by count: Int) -> Int? {
        guard let currentFrame, frameCount > 0, count > 0 else { return nil }

        let nextFrame = (currentFrame - 1 + count % frameCount) % frameCount + 1
        self.currentFrame = nextFrame
        return nextFrame
    }
}
