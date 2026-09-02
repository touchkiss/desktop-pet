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
