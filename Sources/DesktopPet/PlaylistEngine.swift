import Foundation

@MainActor
final class PlaylistEngine {
    private(set) var currentClipID: String?
    private(set) var currentFrameIndex: Int = 1

    private weak var store: LibraryStore?
    private var timer: Timer?
    private var recentIDs: [String] = []

    /// When true, stay on the last frame until `resumeAfterHold(playNext:)` is called.
    private var holdingAtEnd = false
    private var pendingNextID: String?
    private var endingSoonFired = false

    /// Called when a clip reaches its last frame. Return `true` to advance immediately,
    /// or `false` to hold on the last frame (caller must later call `resumeAfterHold`).
    var clipFinishedHandler: ((String?) -> Bool)?

    /// Called ONCE per clip pass when remaining play time drops below
    /// `endingSoonLeadTime` (argument = seconds actually remaining). Lets a
    /// teleport start its vanish effect while the clip is still moving.
    var clipEndingSoonHandler: ((TimeInterval) -> Void)?
    var endingSoonLeadTime: TimeInterval = 0.75

    func attach(store: LibraryStore) {
        self.store = store
        if currentClipID == nil {
            currentClipID = store.state.playableClips.first?.id
            currentFrameIndex = 1
        }
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        holdingAtEnd = false
        pendingNextID = nil
        endingSoonFired = false
        guard let store,
              let id = currentClipID,
              let clip = store.clip(id: id),
              clip.frameCount > 0,
              clip.fps > 0 else {
            return
        }
        let interval = 1.0 / clip.fps
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func playClip(id: String) {
        holdingAtEnd = false
        pendingNextID = nil
        currentClipID = id
        currentFrameIndex = 1
        remember(id)
        store?.recordPlay(id: id)
        restartTimer()
        NotificationCenter.default.post(name: .playbackDidChange, object: id)
    }

    /// Start playing from the first item in the current playable set.
    func playFromQueueStart() {
        guard let first = store?.state.playableClips.first?.id else { return }
        playClip(id: first)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        holdingAtEnd = false
        pendingNextID = nil
    }

    /// Release a clip-end hold. If `playNext` is true, play the queued next clip (or loop).
    func resumeAfterHold(playNext: Bool = true) {
        guard holdingAtEnd else { return }
        let next = pendingNextID
        holdingAtEnd = false
        pendingNextID = nil
        guard playNext else {
            currentFrameIndex = 1
            endingSoonFired = false
            return
        }
        if let next {
            playClip(id: next)
        } else {
            currentFrameIndex = 1
            endingSoonFired = false
        }
    }

    private func tick() {
        if holdingAtEnd { return }

        guard let store,
              let id = currentClipID,
              let clip = store.clip(id: id) else {
            stop()
            return
        }

        if currentFrameIndex < clip.frameCount {
            currentFrameIndex += 1
            notifyEndingSoonIfNeeded(clip: clip)
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
        guard !endingSoonFired, clip.fps > 0 else { return }
        let remaining = Double(clip.frameCount - currentFrameIndex) / clip.fps
        guard remaining <= endingSoonLeadTime else { return }
        endingSoonFired = true
        clipEndingSoonHandler?(max(0, remaining))
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
