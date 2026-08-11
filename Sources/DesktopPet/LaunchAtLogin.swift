import Foundation
import ServiceManagement
import AppKit

enum LaunchAtLogin {
    /// Whether the app is currently registered as a login item.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Human-readable status for UI / error messages.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "已开启"
        case .notRegistered:
            return "未开启"
        case .notFound:
            return "未找到应用（请通过 DesktopPet.app 启动）"
        case .requiresApproval:
            return "等待系统批准（系统设置 → 通用 → 登录项）"
        @unknown default:
            return "未知状态"
        }
    }

    /// Enable or disable launch at login. Returns an error message on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        // Prefer registering the .app bundle; bare binaries often report .notFound.
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return nil }
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .notRegistered { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Whether macOS is waiting for the user to approve the login item.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Open System Settings to the Login Items pane when approval is needed.
    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.general?LoginItems") {
            NSWorkspace.shared.open(url)
        }
    }
}
