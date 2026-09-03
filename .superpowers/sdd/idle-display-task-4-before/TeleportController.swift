import AppKit
import DesktopPetCore

@MainActor
final class TeleportController {
    private enum Phase {
        case idle
        case vanishing
        case hidden
        case appearing
    }

    private enum TripProvenance {
        case autonomous
        case explicit

        var isAutonomous: Bool {
            self == .autonomous
        }
    }

    private enum LandingPresentation {
        case effect
        case swarm
    }

    private let store: LibraryStore
    private let pet: PetWindowController
    private let engine: PlaylistEngine
    private let effects: TeleportEffectRenderer
    private let cursorPreyOverlay = CursorPreyOverlayController()

    private var phase: Phase = .idle
    private var hiddenWork: DispatchWorkItem?
    private var petOrderedVisible = true
    private var originMovedThisTrip = false
    private var pendingMode: TeleportLandingMode = .corner
    /// Vanish and appear styles are independent draws — any combination,
    /// with a bridge only spanning move-style pairs.
    private var vanishStyle: TeleportEffectStyle = .blink
    private var appearStyle: TeleportEffectStyle = .blink
    /// Trip geometry, resolved up-front so vanish / streak / appear all share
    /// one consistent direction.
    private var pendingDestination: CGPoint?
    private var travelFrom: CGPoint = .zero
    private var travelTo: CGPoint = .zero
    private var travelDirection = CGVector(dx: 0, dy: 1)
    private var travelSpan: CGFloat = 100
    /// Bubble text shown on arrival instead of a random reminder.
    private var arrivalMessage: String?
    /// The bridge effect spanning the hidden gap (comet / cloud / vortex /
    /// shadow hops), or .none for a classic silent reappearance.
    private var middleThisTrip: TravelMiddle = .none
    private let streak = TravelStreakRenderer()
    private let swarm = TileSwarmRenderer()
    /// True while we asked the engine to hold on the last frame of a clip.
    private var holdingEngine = false
    private var cursorInteraction = CursorInteractionSessionState()
    private var suppressReminderThisTrip = false

    init(store: LibraryStore, pet: PetWindowController, engine: PlaylistEngine) {
        self.store = store
        self.pet = pet
        self.engine = engine
        self.effects = TeleportEffectRenderer(host: pet.effectHost)
        effects.setEffectPadding = { [weak pet] padding in
            pet?.setTeleportEffectPadding(padding)
        }
        pet.onTeleportDragCancel = { [weak self] in
            self?.cancelInFlight(reschedule: true)
        }
        engine.clipFinishedHandler = { [weak self] nextID in
            self?.handleClipFinished(nextID: nextID) ?? true
        }
        engine.clipEndingSoonHandler = { [weak self] remaining in
            self?.handleClipEndingSoon(remaining: remaining)
        }
        effects.setLiveImageSuppressed = { [weak pet] suppressed in
            pet?.suppressLiveImageForEffect = suppressed
        }
        pet.onFrameRendered = { [weak self] image in
            self?.effects.updateLiveFrame(image)
        }
        pet.onFrameLoadFailed = { [weak self] clipID, _ in
            self?.handleFrameLoadFailure(clipID: clipID)
        }
        cursorPreyOverlay.onFailure = { [weak self] in
            self?.failCursorInteraction(restorePlayback: true)
        }
    }

    func start() {
        syncFromStore()
    }

    func stop() {
        cancelInFlight(reschedule: false)
    }

    func setPetVisible(_ visible: Bool) {
        petOrderedVisible = visible
        if !visible {
            cancelInFlight(reschedule: false)
        } else {
            syncFromStore()
        }
    }

    func syncFromStore() {
        if cursorInteraction.phase != .idle,
           !isPreparedInteractionStillValid() {
            if cursorInteraction.phase == .active, engine.isPlayingOneShot {
                // Let the engine's authoritative abnormal-termination signal
                // clear the overlay/session before it restores ordinary play.
                engine.cancelOneShotAndRestore(reason: .sourceInvalidated)
            } else {
                cleanupCursorInteraction(restorePlayback: false)
            }
        }
        guard store.state.teleportEnabled, petOrderedVisible else {
            cancelInFlight(reschedule: false)
            pet.restorePetPresentation()
            return
        }
        // Idle waiting for next clip-end; nothing to schedule.
    }

    /// Fires ~0.75s before the clip ends: roll the dice and, on a hit, start
    /// the vanish WHILE THE CLIP IS STILL PLAYING — the cat is alive and
    /// moving as it dissolves, instead of freezing into a static sticker.
    private func handleClipEndingSoon(remaining: TimeInterval) {
        _ = remaining
        guard store.state.teleportEnabled,
              petOrderedVisible,
              phase == .idle,
              cursorInteraction.phase == .idle,
              !pet.isFlinging else {
            return
        }
        let roll = Double.random(in: 0...1)
        guard TeleportMath.shouldTeleportAtClipEnd(
            frequency: store.state.teleportFrequency,
            unitRandom: roll
        ) else { return }
        beginTrip()
    }

    /// - Returns: `true` if the engine should advance immediately.
    private func handleClipFinished(nextID: String?) -> Bool {
        _ = nextID
        // Mid-trip: hold on the last frame. beginAppear releases the hold,
        // so the NEXT clip is already playing while the cat materializes.
        guard phase == .idle else {
            holdingEngine = true
            return false
        }
        return true
    }

    private func beginTrip() {
        guard store.state.teleportEnabled else { return }
        let pair = TeleportMath.resolveStylePair(
            vanishDraw: TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1)),
            appearDraw: TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1))
        )
        startTrip(vanish: pair.vanish, appear: pair.appear, provenance: .autonomous)
    }

    /// Debug / tuning entry: run a full trip immediately, bypassing the
    /// dice and the enabled toggle. A chosen style is used for BOTH ends
    /// (predictable for tuning); nil draws both ends independently.
    func previewTrip(style: TeleportEffectStyle?) {
        if let style {
            startTrip(vanish: style, appear: style, provenance: .explicit)
        } else {
            let pair = TeleportMath.resolveStylePair(
                vanishDraw: TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1)),
                appearDraw: TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1))
            )
            startTrip(vanish: pair.vanish, appear: pair.appear, provenance: .explicit)
        }
    }

    /// Full teleport chain that lands near the cursor (hotkey, pomodoro,
    /// download sniffer), optionally with a specific arrival bubble.
    func summonToCursor(message: String? = nil) {
        let pair = TeleportMath.resolveStylePair(
            vanishDraw: TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1)),
            appearDraw: TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1))
        )
        startTrip(
            vanish: pair.vanish,
            appear: pair.appear,
            provenance: .explicit,
            landing: .cursorNudge,
            arrivalMessage: message
        )
    }

    /// Immediate speech bubble on the pet (petting feedback, status notes).
    func showBubble(_ text: String) {
        effects.showReminderBubble(text: text, near: pet.effectHost)
    }

    private func startTrip(
        vanish: TeleportEffectStyle,
        appear: TeleportEffectStyle,
        provenance: TripProvenance,
        landing: TeleportLandingMode? = nil,
        arrivalMessage message: String? = nil
    ) {
        if !provenance.isAutonomous, cursorInteraction.phase != .idle {
            cancelInFlight(reschedule: false)
        }
        guard petOrderedVisible,
              phase == .idle,
              !pet.isFlinging,
              !provenance.isAutonomous || cursorInteraction.phase == .idle else {
            return
        }
        // The trip owns window geometry until finishTrip / cancel.
        pet.freezeFrameForTeleport = true
        vanishStyle = vanish
        appearStyle = appear
        arrivalMessage = message
        suppressReminderThisTrip = false
        pendingMode = landing ?? TeleportMath.pickLandingMode(
            nudgeEnabled: store.state.cursorNudgeEnabled,
            unitRandom: Double.random(in: 0...1)
        )
        originMovedThisTrip = false

        // Resolve the landing spot NOW so the whole trip shares one
        // direction: vanish dashes towards it, the streak flies to it,
        // and appear slides in from it.
        let frame = pet.currentPetFrame()
        let destination = resolveDestination()
        prepareCursorInteractionIfEligible(
            isAutonomous: provenance.isAutonomous,
            hasExplicitArrivalMessage: message != nil
        )
        pendingDestination = destination
        travelFrom = CGPoint(x: frame.midX, y: frame.midY)
        travelTo = CGPoint(
            x: destination.x + frame.width / 2,
            y: destination.y + frame.height / 2
        )
        let dx = travelTo.x - travelFrom.x
        let dy = travelTo.y - travelFrom.y
        let length = max(1, hypot(dx, dy))
        travelDirection = CGVector(dx: dx / length, dy: dy / length)
        travelSpan = max(frame.width, frame.height)
        // Which bridge (if any) spans the hidden gap for this pair.
        middleThisTrip = TeleportMath.pickTravelMiddle(
            vanishStyle: vanish,
            appearStyle: appear,
            unitRandom: Double.random(in: 0...1)
        )

        // 像素洪流 is one integrated journey — a dedicated renderer carries
        // the whole trip; no separate vanish / bridge / appear stages.
        if vanish == .swarm {
            beginSwarmTrip()
            return
        }

        phase = .vanishing
        effects.playVanish(
            style: vanishStyle,
            onPet: pet.effectHost,
            towards: travelDirection
        ) { [weak self] in
            self?.enterHidden()
        }
    }

    private func enterHidden() {
        guard phase == .vanishing else { return }
        phase = .hidden
        pet.setPetHiddenForTeleport(true)

        if let destination = pendingDestination {
            pet.movePetForTeleport(to: destination)
            originMovedThisTrip = true
        }

        let pause = TeleportMath.hiddenDuration(frequency: store.state.teleportFrequency)
        if middleThisTrip != .none {
            // The bridge occupies the tail of the hidden pause: silence
            // first, then it flies and its arrival triggers the appear.
            let distance = Double(hypot(travelTo.x - travelFrom.x, travelTo.y - travelFrom.y))
            let travel = TeleportMath.travelDuration(distance: distance)
            let wait = max(0.05, pause - travel)
            let work = DispatchWorkItem { [weak self] in self?.launchMiddle() }
            hiddenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        } else {
            // No bridge this trip — classic silent reappearance.
            let work = DispatchWorkItem { [weak self] in self?.beginAppear() }
            hiddenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
        }
    }

    private func beginSwarmTrip() {
        guard let snapshot = pet.petSnapshot(), let destination = pendingDestination else {
            cancelInFlight(reschedule: false)
            return
        }
        phase = .vanishing
        let fromRect = pet.currentPetFrame()
        let toRect = CGRect(origin: destination, size: fromRect.size)
        pet.setPetHiddenForTeleport(true)
        pet.movePetForTeleport(to: destination)
        swarm.play(fromRect: fromRect, toRect: toRect, snapshot: snapshot) { [weak self] in
            guard let self, self.phase == .vanishing else { return }
            self.phase = .appearing
            self.prepareLandingPresentation(.swarm)
        }
    }

    private func launchMiddle() {
        guard phase == .hidden else { return }
        streak.play(
            from: travelFrom,
            to: travelTo,
            petSpan: travelSpan,
            style: vanishStyle,
            middle: middleThisTrip,
            rider: effects.lastPetSnapshot
        ) { [weak self] in
            self?.beginAppear()
        }
    }

    private func resolveDestination() -> CGPoint {
        let frame = pet.currentPetFrame()
        let size = frame.size
        let screens = NSScreen.screens.map { TeleportScreenBox(visibleFrame: $0.visibleFrame) }
        guard !screens.isEmpty else { return frame.origin }

        if pendingMode == .cursorNudge {
            let cursor = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
            if let screen,
               let nudge = TeleportMath.cursorNudgeOrigin(
                cursor: cursor,
                petSize: size,
                visibleFrame: screen.visibleFrame,
                angleUnit: Double.random(in: 0...1),
                radiusUnit: Double.random(in: 0...1)
               ) {
                return nudge
            }
            pendingMode = .corner
        }

        var randoms: [Double] = []
        for _ in 0..<48 { randoms.append(Double.random(in: 0...1)) }
        return TeleportMath.pickCornerOrigin(
            screens: screens,
            petSize: size,
            currentOrigin: frame.origin,
            unitRandoms: randoms
        )
    }

    private func beginAppear() {
        guard phase == .hidden else { return }
        phase = .appearing
        prepareLandingPresentation(.effect)
    }

    /// Shared arrival ordering for classic effects and the integrated swarm:
    /// cursor prey, interaction clip from frame 1, then visible cat presentation.
    private func prepareLandingPresentation(_ presentation: LandingPresentation) {
        guard phase == .appearing else { return }
        let interactionStarted = startPendingCursorInteraction()
        if !interactionStarted {
            releaseEngineHold()
        }
        pet.refreshFrame()

        // A successful interaction is already on frame 1 and must be
        // presented before even a single-frame clip can complete. Preserve
        // the classic path's existing settling delay only for its ordinary
        // non-interactive fallback; swarm has always handed off immediately.
        if interactionStarted || presentation == .swarm {
            presentLanding(presentation)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.presentLanding(presentation)
            }
        }
    }

    private func presentLanding(_ presentation: LandingPresentation) {
        guard phase == .appearing else { return }
        // Window frames are frozen for the whole trip; place the landing
        // frame exactly once, sized for the clip that is about to appear and
        // centered on the landing point. Effect, canvas and live window share
        // this rect, so no tick-ordering can shift it later.
        placeLandingFrame()
        switch presentation {
        case .effect:
            pet.effectHost.alphaValue = 0
            pet.setPetHiddenForTeleport(false)
            effects.playAppear(
                style: appearStyle,
                onPet: pet.effectHost,
                towards: travelDirection
            ) { [weak self] in
                self?.finishTrip()
            }
        case .swarm:
            pet.effectHost.alphaValue = 1
            pet.setPetHiddenForTeleport(false)
            finishTrip()
        }
    }

    private func placeLandingFrame() {
        guard let clipID = engine.currentClipID,
              let clip = store.clip(id: clipID) else { return }
        let size = clip.effectiveDisplaySize(globalScale: store.state.petScale)
        pet.setTeleportLandingFrame(center: travelTo, size: size)
    }

    private func prepareCursorInteractionIfEligible(
        isAutonomous: Bool,
        hasExplicitArrivalMessage: Bool
    ) {
        guard cursorInteraction.phase == .idle,
              isAutonomous,
              pendingMode == .cursorNudge,
              !hasExplicitArrivalMessage else {
            return
        }

        let preyCandidates = store.state.clips.filter(isValidPreyCandidate)
        let interactionCandidates = store.state.clips.filter(isValidInteractionCandidate)
        // A malformed legacy entry may carry both tags. Only consider prey
        // choices that still leave at least one distinct cat action.
        let pairablePreyCandidates = preyCandidates.filter { prey in
            interactionCandidates.contains { $0.id != prey.id }
        }

        guard CursorInteractionPolicy.isInteractionEligible(
            isAutonomous: isAutonomous,
            landingMode: pendingMode,
            hasPreyCandidate: !pairablePreyCandidates.isEmpty,
            hasInteractionCandidate: !interactionCandidates.isEmpty
        ),
        let prey = pairablePreyCandidates.randomElement(),
        let interaction = interactionCandidates
            .filter({ $0.id != prey.id })
            .randomElement() else {
            return
        }

        _ = cursorInteraction.prepare(
            preyID: prey.id,
            interactionID: interaction.id
        )
    }

    private func startPendingCursorInteraction() -> Bool {
        guard cursorInteraction.phase == .pending else { return false }
        guard let preyID = cursorInteraction.preyID,
              let interactionID = cursorInteraction.interactionID,
              let prey = store.clip(id: preyID),
              let interaction = store.clip(id: interactionID),
              preyID != interactionID,
              isValidPreyCandidate(prey),
              isValidInteractionCandidate(interaction) else {
            cleanupCursorInteraction(restorePlayback: true)
            return false
        }

        let settings = prey.cursorPreySettings ?? CursorPreySettings()
        guard cursorPreyOverlay.start(clip: prey, settings: settings) else {
            cleanupCursorInteraction(restorePlayback: true)
            return false
        }

        let started = engine.playHeldCursorInteraction(
            id: interactionID,
            completion: { [weak self] in
                self?.completeCursorInteraction(expectedInteractionID: interactionID)
            },
            cancellation: { [weak self] _ in
                self?.cancelCursorInteractionFromEngine(
                    expectedInteractionID: interactionID
                )
            }
        )
        guard started else {
            cleanupCursorInteraction(restorePlayback: true)
            return false
        }

        // playHeldCursorInteraction consumed the engine's hold. Clearing the
        // controller flag prevents finish/cancel from advancing it again.
        holdingEngine = false
        guard cursorInteraction.activate() else {
            // The engine has already consumed the hold, so rollback is an
            // interrupted one-shot restoration rather than a hold release.
            _ = cursorInteraction.clear()
            cursorPreyOverlay.stop()
            if engine.isPlayingOneShot {
                engine.cancelOneShotAndRestore()
            }
            return false
        }
        suppressReminderThisTrip = true
        return true
    }

    private func isPreparedInteractionStillValid() -> Bool {
        guard let preyID = cursorInteraction.preyID,
              let interactionID = cursorInteraction.interactionID,
              preyID != interactionID,
              let prey = store.clip(id: preyID),
              let interaction = store.clip(id: interactionID) else {
            return false
        }
        return isValidPreyCandidate(prey) && isValidInteractionCandidate(interaction)
    }

    private func isValidPreyCandidate(_ clip: PetClip) -> Bool {
        clip.tags.contains(ClipTag.cursorPrey) && isRenderableCandidate(clip)
    }

    private func isValidInteractionCandidate(_ clip: PetClip) -> Bool {
        clip.tags.contains(ClipTag.cursorInteraction)
            && isRenderableCandidate(clip)
            && hasDecodableFirstFrame(clip)
    }

    private func isRenderableCandidate(_ clip: PetClip) -> Bool {
        clip.frameCount > 0
            && clip.fps.isFinite
            && clip.fps > 0
            && clip.displayWidth > 0
            && clip.displayHeight > 0
    }

    private func hasDecodableFirstFrame(_ clip: PetClip) -> Bool {
        let url = AppPaths.clipsRoot
            .appendingPathComponent(clip.id, isDirectory: true)
            .appendingPathComponent("frames", isDirectory: true)
            .appendingPathComponent("00001.png")
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0 else {
            return false
        }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) != nil
    }

    private func completeCursorInteraction(expectedInteractionID: String) {
        guard cursorInteraction.phase == .active,
              cursorInteraction.interactionID == expectedInteractionID else {
            return
        }
        // PlaylistEngine has already resolved its one-shot state and owns
        // ordinary restoration after this callback returns.
        cleanupCursorInteraction(restorePlayback: false)
    }

    private func cancelCursorInteractionFromEngine(expectedInteractionID: String) {
        guard cursorInteraction.phase != .idle,
              cursorInteraction.interactionID == expectedInteractionID else {
            return
        }
        // The engine is already applying the external playback/stop/restore
        // mutation that caused this callback. Only clear presentation state.
        failCursorInteraction(restorePlayback: false)
    }

    private func handleFrameLoadFailure(clipID: String) {
        guard cursorInteraction.shouldCancelForFrameFailure(
            clipID: clipID,
            currentClipID: engine.currentClipID,
            isPlayingOneShot: engine.isPlayingOneShot
        ) else {
            return
        }
        engine.cancelOneShotAndRestore(reason: .sourceInvalidated)
        // The failed frame was already cleared. Force the restored ordinary
        // frame now, even when its (clipID, frameIndex) matches AppDelegate's
        // last-rendered key (for example, a single-frame loop).
        pet.refreshFrame()
    }

    private func failCursorInteraction(restorePlayback: Bool) {
        // If startup/rendering fails before the arrival finishes, preserve
        // the original cursor-near reminder fallback for this trip.
        suppressReminderThisTrip = false
        cleanupCursorInteraction(restorePlayback: restorePlayback)
    }

    private func cleanupCursorInteraction(restorePlayback: Bool) {
        let cleanup = cursorInteraction.clear()
        cursorPreyOverlay.stop()
        guard restorePlayback,
              cleanup == .active,
              engine.isPlayingOneShot else {
            return
        }
        engine.cancelOneShotAndRestore()
    }

    private func finishTrip() {
        guard phase == .appearing else { return }
        if pendingMode == .cursorNudge, !suppressReminderThisTrip {
            let text: String?
            if let arrivalMessage {
                text = arrivalMessage
            } else {
                text = store.state.reminderMessages
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .randomElement()
            }
            if let text {
                effects.showReminderBubble(text: text, near: pet.effectHost)
            }
        }
        arrivalMessage = nil
        suppressReminderThisTrip = false
        phase = .idle
        pet.freezeFrameForTeleport = false
        releaseEngineHold()
    }

    private func cancelInFlight(reschedule: Bool) {
        hiddenWork?.cancel()
        hiddenWork = nil
        streak.cancel()
        swarm.cancel()
        effects.cancel()
        cleanupCursorInteraction(restorePlayback: true)
        pet.restorePetPresentation()
        phase = .idle
        originMovedThisTrip = false
        pendingDestination = nil
        arrivalMessage = nil
        suppressReminderThisTrip = false
        // Always release a hold so playback does not freeze forever.
        releaseEngineHold()
        _ = reschedule // clip-end driven; next opportunity is the next clip finish
    }

    private func releaseEngineHold() {
        guard holdingEngine else { return }
        holdingEngine = false
        engine.resumeAfterHold(playNext: true)
    }
}
