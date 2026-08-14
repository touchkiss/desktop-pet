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

    private let store: LibraryStore
    private let pet: PetWindowController
    private let engine: PlaylistEngine
    private let effects: TeleportEffectRenderer

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
        guard store.state.teleportEnabled, petOrderedVisible, phase == .idle, !pet.isFlinging else { return }
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
        startTrip(vanish: pair.vanish, appear: pair.appear)
    }

    /// Debug / tuning entry: run a full trip immediately, bypassing the
    /// dice and the enabled toggle. A chosen style is used for BOTH ends
    /// (predictable for tuning); nil draws both ends independently.
    func previewTrip(style: TeleportEffectStyle?) {
        if let style {
            startTrip(vanish: style, appear: style)
        } else {
            let pair = TeleportMath.resolveStylePair(
                vanishDraw: TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1)),
                appearDraw: TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1))
            )
            startTrip(vanish: pair.vanish, appear: pair.appear)
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
        landing: TeleportLandingMode? = nil,
        arrivalMessage message: String? = nil
    ) {
        guard petOrderedVisible, phase == .idle, !pet.isFlinging else { return }
        // The trip owns window geometry until finishTrip / cancel.
        pet.freezeFrameForTeleport = true
        vanishStyle = vanish
        appearStyle = appear
        arrivalMessage = message
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
            pet.freezeFrameForTeleport = false
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
            self.pet.setPetHiddenForTeleport(false)
            self.pet.effectHost.alphaValue = 1
            self.finishTrip()
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
        // Release the hold FIRST: the next clip starts and its frames flow
        // into the effect's staging layers, so the cat is already moving
        // while it materializes. The short delay lets the window resize to
        // the new clip before the effect measures its geometry.
        releaseEngineHold()
        pet.setPetHiddenForTeleport(false)
        pet.effectHost.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.phase == .appearing else { return }
            // Window frames are frozen for the whole trip; place the
            // landing frame exactly once, sized for the clip that is about
            // to appear and centered on the landing point. The effect, its
            // canvas and the restored live window all share this ONE rect —
            // no tick-ordering can shift it anymore.
            self.placeLandingFrame()
            self.effects.playAppear(
                style: self.appearStyle,
                onPet: self.pet.effectHost,
                towards: self.travelDirection
            ) { [weak self] in
                self?.finishTrip()
            }
        }
    }

    private func placeLandingFrame() {
        guard let clipID = engine.currentClipID,
              let clip = store.clip(id: clipID) else { return }
        let scale = max(0.35, min(store.state.petScale, 3.0))
        let size = CGSize(
            width: CGFloat(clip.displayWidth) * scale,
            height: CGFloat(clip.displayHeight) * scale
        )
        pet.setTeleportLandingFrame(center: travelTo, size: size)
    }

    private func finishTrip() {
        guard phase == .appearing else { return }
        if pendingMode == .cursorNudge {
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
        pet.restorePetPresentation()
        phase = .idle
        originMovedThisTrip = false
        pendingDestination = nil
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
