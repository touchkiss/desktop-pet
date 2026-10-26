import AppKit
import DesktopPetCore

/// Register once with the workspace's own center, including while no surface plays.
@MainActor
final class PlaybackPowerMonitor: NSObject {
    static let shared = PlaybackPowerMonitor(notificationCenter: NSWorkspace.shared.notificationCenter)
    static let didChange = Notification.Name("DesktopPet.playbackPowerDidChange")
    let changes = NotificationCenter()
    private var state = PlaybackSuspensionState()
    private let notificationCenter: NotificationCenter

    var isSuspended: Bool { state.isSuspended }

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
        super.init()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            notificationCenter.addObserver(self, selector: #selector(powerChanged(_:)), name: name, object: nil)
        }
    }

    deinit { notificationCenter.removeObserver(self) }

    @objc private func powerChanged(_ note: Notification) {
        let reason: PlaybackSuspensionState.Reason
        let sleeping: Bool
        switch note.name {
        case NSWorkspace.willSleepNotification: reason = .system; sleeping = true
        case NSWorkspace.didWakeNotification: reason = .system; sleeping = false
        case NSWorkspace.screensDidSleepNotification: reason = .display; sleeping = true
        case NSWorkspace.screensDidWakeNotification: reason = .display; sleeping = false
        default: return
        }
        if state.setSleeping(sleeping, reason: reason) {
            changes.post(name: Self.didChange, object: self)
        }
    }
}
