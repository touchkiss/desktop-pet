### Task 5: Connect IOKit and real HID idle time

**Files:**
- Create: `Sources/DesktopPet/IOKitIdleDisplaySleepController.swift`
- Modify: `Package.swift`
- Modify: `Sources/DesktopPet/AppDelegate.swift`

**Interfaces:**
- Consumes: `IdleDisplaySleepLease`, `IdlePresentationPolicy`, persisted state, library error UI, and pet phase setter.
- Produces: live display assertion and one-second idle-phase synchronization.

- [ ] **Step 1: Implement the IOKit adapter using the already-tested lease**

```swift
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
    func setEnabled(_ enabled: Bool) throws { try lease.setEnabled(enabled) }
}
```

- [ ] **Step 2: Link IOKit**

Add `.linkedFramework("IOKit")` beside the existing `ServiceManagement` and `Carbon` linker settings in `Package.swift`.

- [ ] **Step 3: Add AppDelegate runtime synchronization**

Add properties:

```swift
private let idleDisplaySleepController = IOKitIdleDisplaySleepController()
private var idlePresentationTimer: Timer?
private var currentIdlePresentationPhase: IdlePresentationPhase = .normal
private var isRecoveringDisplaySleepSetting = false
```

At launch, synchronize the saved assertion and start a repeating one-second common-run-loop timer. Keep the sampling method small:

```swift
private func updateIdlePresentation() {
    let rawIdle = CGEventSource.secondsSinceLastEventType(
        .hidSystemState,
        eventType: .null
    )
    let phase = IdlePresentationPolicy.phase(
        idleSeconds: rawIdle,
        delay: store.state.manicIdleDelay
    )
    guard phase != currentIdlePresentationPhase else { return }
    currentIdlePresentationPhase = phase
    petWindow?.setIdlePresentationPhase(phase)
}
```

In `handleLibraryChange`, call both `synchronizeIdleDisplaySleep()` and `updateIdlePresentation()` before refreshing the current frame. Use a recursion guard for assertion failure:

```swift
private func synchronizeIdleDisplaySleep() {
    guard !isRecoveringDisplaySleepSetting else { return }
    do {
        try idleDisplaySleepController.setEnabled(store.state.preventIdleDisplaySleep)
    } catch {
        isRecoveringDisplaySleepSetting = true
        store.update { $0.preventIdleDisplaySleep = false }
        isRecoveringDisplaySleepSetting = false
        libraryWindow?.presentIdleDisplaySleepError(error.localizedDescription)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }
}
```

Add termination cleanup:

```swift
func applicationWillTerminate(_ notification: Notification) {
    idlePresentationTimer?.invalidate()
    idlePresentationTimer = nil
    do {
        try idleDisplaySleepController.setEnabled(false)
    } catch {
        NSLog("DesktopPet: %@", error.localizedDescription)
    }
}
```

Also call `setEnabled(false)` in `quit()` before `NSApp.terminate(nil)` only if needed to guarantee immediate release; the lease makes duplicate disable calls safe.

- [ ] **Step 4: Build and verify symbols link**

Run: `swift build`

Expected: executable links successfully with IOKit and no unresolved `IOPMAssertion*` symbols.

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 5: Stage only runtime feature hunks and commit**

```bash
git add Sources/DesktopPet/IOKitIdleDisplaySleepController.swift
git add -p Package.swift Sources/DesktopPet/AppDelegate.swift
git diff --cached --check
git diff --cached
git commit -m "[电源] 接入空闲显示保护与魔性阶段计时"
```

Reject pre-existing AppDelegate hunks that are unrelated to the assertion, idle timer, phase synchronization, or termination cleanup.

