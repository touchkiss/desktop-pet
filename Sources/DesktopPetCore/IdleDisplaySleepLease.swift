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
