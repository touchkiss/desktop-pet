import Foundation
import IOKit.pwr_mgt
import DesktopPetCore

struct IOKitPowerAssertionError: LocalizedError {
    let operation: String
    let code: IOReturn

    var errorDescription: String? {
        "\(operation)失败（系统错误码 \(code)）"
    }
}

final class IOKitIdleDisplaySleepController {
    private lazy var lease = IdleDisplaySleepLease(
        acquire: {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "DesktopPet 用户已启用显示保护" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                throw IOKitPowerAssertionError(operation: "创建显示保护", code: result)
            }
            return id
        },
        release: { id in
            let result = IOPMAssertionRelease(id)
            guard result == kIOReturnSuccess else {
                throw IOKitPowerAssertionError(operation: "释放显示保护", code: result)
            }
        }
    )

    var isEnabled: Bool { lease.isEnabled }

    func setEnabled(_ enabled: Bool) throws {
        try lease.setEnabled(enabled)
    }
}
