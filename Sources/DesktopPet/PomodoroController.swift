import Foundation

/// 25 + 5 pomodoro. The cat is the notifier: when a phase ends the app
/// summons it to the cursor with the suggestion bubble.
@MainActor
final class PomodoroController {
    enum Phase: Equatable {
        case idle
        case focus
        case rest
    }

    private(set) var phase: Phase = .idle
    private var timer: Timer?

    let focusMinutes = 25
    let restMinutes = 5

    /// (phase that just ended, suggestion to show)
    var onPhaseEnd: ((Phase, String) -> Void)?

    var isRunning: Bool { phase != .idle }

    func start() {
        enter(.focus)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        phase = .idle
    }

    private func enter(_ newPhase: Phase) {
        timer?.invalidate()
        phase = newPhase
        let minutes = newPhase == .focus ? focusMinutes : restMinutes
        let newTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(minutes * 60),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.phaseFinished()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func phaseFinished() {
        switch phase {
        case .focus:
            enter(.rest)
            onPhaseEnd?(.focus, "专注结束，站起来活动一下吧")
        case .rest:
            stop()
            onPhaseEnd?(.rest, "休息够了，继续加油")
        case .idle:
            break
        }
    }
}
