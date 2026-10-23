import Foundation
import DesktopPetCore

enum OneShotCancellationReason {
    case replacedByPlayback
    case stopped
    case requestedRestore
    case sourceInvalidated
}

@MainActor
final class PlaylistEngine {
    private(set) var currentClipID: String?
    private(set) var currentFrameIndex: Int = 1

    /// Delivers completed playback mutations without a separate polling timer.
    var onFrameChanged: (() -> Void)?
    /// Native video clock when available; legacy sequences retain timer-based advancement.
    var playbackTimeProvider: ((String) -> TimeInterval?)?

    private weak var store: LibraryStore?
    private var timer: Timer?
    private var recentIDs: [String] = []

    /// When true, stay on the last frame until `resumeAfterHold(playNext:)` is called.
    private var holdingAtEnd = false
    private var pendingNextID: String?
    private var endingSoonFired = false
    private var oneShotState = OneShotPlaybackState()
    private var oneShotCompletionHandler: (() -> Void)?
    private var oneShotCancellationHandler: ((OneShotCancellationReason) -> Void)?
    private var playbackRevision: UInt = 0
    private var timerRevision: UInt = 0

    /// True only while a cursor-interaction clip is replacing a held ordinary clip.
    var isPlayingOneShot: Bool {
        oneShotState.isActive
    }

    /// Called when a clip reaches its last frame. Return `true` to advance immediately,
    /// or `false` to hold on the last frame (caller must later call `resumeAfterHold`).
    var clipFinishedHandler: ((String?) -> Bool)?

    /// Called ONCE per clip pass when remaining play time drops below
    /// `endingSoonLeadTime` (argument = seconds actually remaining). Lets a
    /// teleport start its vanish effect while the clip is still moving.
    var clipEndingSoonHandler: ((TimeInterval) -> Void)?
    var endingSoonLeadTime: TimeInterval = 0.75

    func attach(store: LibraryStore) {
        defer { onFrameChanged?() }
        self.store = store
        if currentClipID == nil {
            advancePlaybackRevision()
            currentClipID = store.state.playableClips.first?.id
            currentFrameIndex = 1
        }
        restartTimer()
    }

    func restartTimer() {
        invalidateTimer()
        holdingAtEnd = false
        pendingNextID = nil
        endingSoonFired = false
        guard let store,
              let id = currentClipID,
              let clip = store.clip(id: id),
              clip.frameCount > 0,
              clip.fps.isFinite,
              clip.fps > 0 else {
            return
        }
        let interval = 1.0 / clip.fps
        guard interval.isFinite, interval > 0 else { return }

        let revision = timerRevision
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick(timerRevision: revision)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func playClip(id: String) {
        playClip(id: id, notifyingObservers: true)
    }

    func playClip(id: String, notifyingObservers: Bool) {
        defer { onFrameChanged?() }
        let requestRevision = advancePlaybackRevision()
        cancelOneShot(reason: .replacedByPlayback)
        guard PlaybackRevisionPolicy.shouldAccept(
            expected: requestRevision,
            current: playbackRevision
        ) else {
            return
        }
        holdingAtEnd = false
        pendingNextID = nil
        currentClipID = id
        currentFrameIndex = 1
        remember(id)
        store?.recordPlay(id: id)
        restartTimer()
        if notifyingObservers {
            NotificationCenter.default.post(name: .playbackDidChange, object: id)
        }
    }

    /// Replaces an active clip-end hold with one cursor-interaction pass.
    /// The hold's queued ordinary clip remains the preferred return target.
    @discardableResult
    func playHeldCursorInteraction(
        id: String,
        completion: @escaping () -> Void = {},
        cancellation: @escaping (OneShotCancellationReason) -> Void = { _ in }
    ) -> Bool {
        defer { onFrameChanged?() }
        guard holdingAtEnd,
              let store,
              let clip = store.clip(id: id),
              clip.tags.contains(ClipTag.cursorInteraction),
              clip.frameCount > 0,
              clip.fps.isFinite,
              clip.fps > 0 else {
            return false
        }
        let interval = 1.0 / clip.fps
        guard interval.isFinite, interval > 0 else { return false }

        let preferredReturnID = pendingNextID
        let requestRevision = advancePlaybackRevision()
        cancelOneShot(reason: .replacedByPlayback)
        guard PlaybackRevisionPolicy.shouldAccept(
            expected: requestRevision,
            current: playbackRevision
        ) else {
            return false
        }
        holdingAtEnd = false
        pendingNextID = nil
        endingSoonFired = false
        oneShotState.start(interactionID: id, preferredReturnID: preferredReturnID)
        oneShotCompletionHandler = completion
        oneShotCancellationHandler = cancellation
        currentClipID = id
        currentFrameIndex = 1
        store.recordPlay(id: id)
        restartTimer()
        NotificationCenter.default.post(name: .playbackDidChange, object: id)
        return PlaybackRevisionPolicy.shouldAccept(
            expected: requestRevision,
            current: playbackRevision
        ) && oneShotState.isActive && currentClipID == id
    }

    /// Start playing from the first item in the current playable set.
    func playFromQueueStart() {
        guard let first = store?.state.playableClips.first?.id else { return }
        playClip(id: first)
    }

    func stop() {
        defer { onFrameChanged?() }
        let requestRevision = advancePlaybackRevision()
        cancelOneShot(reason: .stopped)
        guard PlaybackRevisionPolicy.shouldAccept(
            expected: requestRevision,
            current: playbackRevision
        ) else {
            return
        }
        invalidateTimer()
        currentClipID = nil
        currentFrameIndex = 1
        holdingAtEnd = false
        pendingNextID = nil
        endingSoonFired = false
        NotificationCenter.default.post(name: .playbackDidChange, object: nil)
    }

    /// Cancels an interrupted one-shot and restores its best valid ordinary target.
    func cancelOneShotAndRestore(
        reason: OneShotCancellationReason = .requestedRestore
    ) {
        guard let resolution = oneShotState.finish(
            availableOrdinaryIDs: store?.state.playableClips.map(\.id) ?? []
        ) else {
            return
        }
        let cancellation = oneShotCancellationHandler
        oneShotCompletionHandler = nil
        oneShotCancellationHandler = nil
        let cancellationRevision = playbackRevision
        cancellation?(reason)
        guard PlaybackRevisionPolicy.shouldAccept(
            expected: cancellationRevision,
            current: playbackRevision
        ) else {
            return
        }
        playOneShotResolution(resolution)
    }

    /// Release a clip-end hold. If `playNext` is true, play the queued next clip (or loop).
    func resumeAfterHold(playNext: Bool = true) {
        defer { onFrameChanged?() }
        guard holdingAtEnd else { return }
        let next = pendingNextID
        holdingAtEnd = false
        pendingNextID = nil
        guard playNext else {
            advancePlaybackRevision()
            currentFrameIndex = 1
            endingSoonFired = false
            return
        }
        if let next {
            playClip(id: next)
        } else {
            advancePlaybackRevision()
            currentFrameIndex = 1
            endingSoonFired = false
        }
    }

    private func tick(timerRevision: UInt) {
        defer { onFrameChanged?() }
        guard PlaybackRevisionPolicy.shouldAccept(
            expected: timerRevision,
            current: self.timerRevision
        ) else {
            return
        }
        if holdingAtEnd { return }

        guard let store,
              let id = currentClipID,
              let clip = store.clip(id: id) else {
            if isPlayingOneShot {
                cancelOneShotAndRestore(reason: .sourceInvalidated)
                return
            }
            stop()
            return
        }

        if currentFrameIndex < clip.frameCount {
            if let time = playbackTimeProvider?(id), time.isFinite, time >= 0 {
                currentFrameIndex = min(clip.frameCount, max(1, Int(floor(time * clip.fps + 0.00001)) + 1))
            } else {
                currentFrameIndex += 1
            }
            if !isPlayingOneShot {
                notifyEndingSoonIfNeeded(clip: clip)
            }
            return
        }

        if isPlayingOneShot {
            completeOneShot()
            return
        }

        let next = pickNext(after: clip, store: store)
        let shouldAdvance = clipFinishedHandler?(next) ?? true
        if shouldAdvance {
            if let next {
                playClip(id: next)
            } else {
                currentFrameIndex = 1
                endingSoonFired = false
            }
        } else {
            holdingAtEnd = true
            pendingNextID = next
        }
    }

    private func notifyEndingSoonIfNeeded(clip: PetClip) {
        guard !endingSoonFired,
              clip.fps.isFinite,
              clip.fps > 0 else {
            return
        }
        let remaining = Double(clip.frameCount - currentFrameIndex) / clip.fps
        guard remaining <= endingSoonLeadTime else { return }
        endingSoonFired = true
        clipEndingSoonHandler?(max(0, remaining))
    }

    private func completeOneShot() {
        guard let resolution = oneShotState.finish(
            availableOrdinaryIDs: store?.state.playableClips.map(\.id) ?? []
        ) else {
            return
        }
        let completion = oneShotCompletionHandler
        oneShotCompletionHandler = nil
        oneShotCancellationHandler = nil
        let completionRevision = playbackRevision
        completion?()
        guard OneShotPlaybackState.shouldApplyCompletionResolution(
            completionRevision: completionRevision,
            currentPlaybackRevision: playbackRevision
        ) else {
            return
        }
        playOneShotResolution(resolution)
    }

    @discardableResult
    private func cancelOneShot(reason: OneShotCancellationReason) -> Bool {
        guard oneShotState.cancel() != nil else { return false }
        let cancellation = oneShotCancellationHandler
        oneShotCompletionHandler = nil
        oneShotCancellationHandler = nil
        cancellation?(reason)
        return true
    }

    @discardableResult
    private func advancePlaybackRevision() -> UInt {
        playbackRevision &+= 1
        return playbackRevision
    }

    private func invalidateTimer() {
        timerRevision &+= 1
        timer?.invalidate()
        timer = nil
    }

    private func playOneShotResolution(_ resolution: OneShotPlaybackState.Resolution) {
        switch resolution {
        case let .play(id):
            playClip(id: id)
        case .stop:
            stop()
        }
    }

    private func pickNext(after clip: PetClip, store: LibraryStore) -> String? {
        let clips = store.state.playableClips
        guard !clips.isEmpty else { return nil }
        if clips.count == 1 { return clip.id }

        // If current clip left the queue, jump to queue start.
        guard clips.contains(where: { $0.id == clip.id }) else {
            return clips.first?.id
        }

        switch store.state.playbackMode {
        case .sequential:
            guard let idx = clips.firstIndex(where: { $0.id == clip.id }) else {
                return clips.first?.id
            }
            return clips[(idx + 1) % clips.count].id

        case .random:
            let others = clips.map(\.id).filter { $0 != clip.id }
            let pool = others.filter { !recentIDs.suffix(2).contains($0) }
            return (pool.isEmpty ? others : pool).randomElement()

        case .graph:
            let candidates = clip.nextClipIDs.filter { id in clips.contains(where: { $0.id == id }) }
            if let pick = candidates.randomElement() {
                return pick
            }
            var bestID: String?
            var bestScore = -1.0
            for other in clips where other.id != clip.id {
                let score = TransitionMatcher.score(from: clip, to: other)
                if score > bestScore {
                    bestScore = score
                    bestID = other.id
                }
            }
            return bestID ?? clips.first(where: { $0.id != clip.id })?.id
        }
    }

    private func remember(_ id: String) {
        recentIDs.append(id)
        if recentIDs.count > 8 {
            recentIDs.removeFirst(recentIDs.count - 8)
        }
    }
}
