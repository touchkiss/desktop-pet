### Task 2: Testable display-sleep lease

**Files:**
- Create: `Sources/DesktopPetCore/IdleDisplaySleepLease.swift`
- Test: `Tests/DesktopPetTests/IdleDisplaySleepLeaseTests.swift`

**Interfaces:**
- Consumes: injected `acquire: () throws -> UInt32` and `release: (UInt32) throws -> Void` closures.
- Produces: `IdleDisplaySleepLease.isEnabled` and `setEnabled(_:) throws`.

- [ ] **Step 1: Write failing lease lifecycle tests**

```swift
import XCTest
@testable import DesktopPetCore

final class IdleDisplaySleepLeaseTests: XCTestCase {
    private enum TestError: Error { case failed }

    func testEnableAndDisableAreIdempotent() throws {
        var acquireCount = 0
        var released: [UInt32] = []
        let lease = IdleDisplaySleepLease(
            acquire: { acquireCount += 1; return 42 },
            release: { released.append($0) }
        )

        try lease.setEnabled(true)
        try lease.setEnabled(true)
        XCTAssertTrue(lease.isEnabled)
        XCTAssertEqual(acquireCount, 1)

        try lease.setEnabled(false)
        try lease.setEnabled(false)
        XCTAssertFalse(lease.isEnabled)
        XCTAssertEqual(released, [42])
    }

    func testFailedAcquireDoesNotClaimEnabled() {
        let lease = IdleDisplaySleepLease(
            acquire: { throw TestError.failed },
            release: { _ in }
        )
        XCTAssertThrowsError(try lease.setEnabled(true))
        XCTAssertFalse(lease.isEnabled)
    }

    func testFailedReleaseClearsLocalLeaseState() throws {
        let lease = IdleDisplaySleepLease(
            acquire: { 7 },
            release: { _ in throw TestError.failed }
        )
        try lease.setEnabled(true)
        XCTAssertThrowsError(try lease.setEnabled(false))
        XCTAssertFalse(lease.isEnabled)
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter IdleDisplaySleepLeaseTests`

Expected: compilation fails because `IdleDisplaySleepLease` does not exist.

- [ ] **Step 3: Implement the minimal lease state machine**

```swift
public final class IdleDisplaySleepLease {
    public typealias Acquire = () throws -> UInt32
    public typealias Release = (UInt32) throws -> Void

    private let acquire: Acquire
    private let release: Release
    private var assertionID: UInt32?

    public var isEnabled: Bool { assertionID != nil }

    public init(acquire: @escaping Acquire, release: @escaping Release) {
        self.acquire = acquire
        self.release = release
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard assertionID == nil else { return }
            assertionID = try acquire()
        } else {
            guard let id = assertionID else { return }
            assertionID = nil
            try release(id)
        }
    }

    deinit {
        guard let id = assertionID else { return }
        try? release(id)
    }
}
```

- [ ] **Step 4: Run focused and full tests**

Run: `swift test --filter IdleDisplaySleepLeaseTests`

Expected: 3 tests pass.

Run: `swift test`

Expected: all tests pass with zero failures.

- [ ] **Step 5: Commit only the new lease files**

```bash
git add Sources/DesktopPetCore/IdleDisplaySleepLease.swift Tests/DesktopPetTests/IdleDisplaySleepLeaseTests.swift
git diff --cached --check
git commit -m "[电源] 新增显示休眠断言租约状态机"
```

