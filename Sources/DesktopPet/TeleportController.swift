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
    private var pendingStyle: TeleportEffectStyle = .portal
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

    /// - Returns: `true` if the engine should advance immediately.
    private func handleClipFinished(nextID: String?) -> Bool {
        guard store.state.teleportEnabled, petOrderedVisible, phase == .idle else {
            return true
        }
        let roll = Double.random(in: 0...1)
        guard TeleportMath.shouldTeleportAtClipEnd(
            frequency: store.state.teleportFrequency,
            unitRandom: roll
        ) else {
            return true
        }
        holdingEngine = true
        beginTrip()
        return false
    }

    private func beginTrip() {
        guard store.state.teleportEnabled, petOrderedVisible, phase == .idle else {
            releaseEngineHold()
            return
        }
        pendingStyle = TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1))
        pendingMode = TeleportMath.pickLandingMode(
            nudgeEnabled: store.state.cursorNudgeEnabled,
            unitRandom: Double.random(in: 0...1)
        )
        originMovedThisTrip = false
        phase = .vanishing
        effects.playVanish(style: pendingStyle, onPet: pet.effectHost) { [weak self] in
            self?.enterHidden()
        }
    }

    private func enterHidden() {
        guard phase == .vanishing else { return }
        phase = .hidden
        pet.setPetHiddenForTeleport(true)

        let destination = resolveDestination()
        pet.movePetForTeleport(to: destination)
        originMovedThisTrip = true

        let pause = TeleportMath.hiddenDuration(frequency: store.state.teleportFrequency)
        let work = DispatchWorkItem { [weak self] in self?.beginAppear() }
        hiddenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
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
        pet.setPetHiddenForTeleport(false)
        pet.effectHost.alphaValue = 0
        effects.playAppear(style: pendingStyle, onPet: pet.effectHost) { [weak self] in
            self?.finishTrip()
        }
    }

    private func finishTrip() {
        guard phase == .appearing else { return }
        if pendingMode == .cursorNudge {
            let messages = store.state.reminderMessages
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let text = messages.randomElement() {
                effects.showReminderBubble(text: text, near: pet.effectHost)
            }
        }
        phase = .idle
        releaseEngineHold()
    }

    private func cancelInFlight(reschedule: Bool) {
        hiddenWork?.cancel()
        hiddenWork = nil
        effects.cancel()
        pet.restorePetPresentation()
        phase = .idle
        originMovedThisTrip = false
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
