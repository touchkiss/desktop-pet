import Foundation

/// Watches ~/Downloads and reports newly finished files. Browser partials
/// are ignored; scans are debounced and reports rate-limited so the cat
/// comments on downloads instead of narrating them.
final class DownloadsWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var known: Set<String> = []
    private var pendingScan: DispatchWorkItem?
    private var lastReport = Date.distantPast

    private static let ignoredExtensions: Set<String> = [
        "part", "crdownload", "download", "tmp", "partial"
    ]

    var onNewFile: ((String) -> Void)?

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil,
              let downloads = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask
              ).first else { return }
        descriptor = open(downloads.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        known = Self.snapshot(of: downloads)

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        newSource.setEventHandler { [weak self] in
            self?.scheduleScan(directory: downloads)
        }
        let fd = descriptor
        newSource.setCancelHandler {
            close(fd)
        }
        newSource.resume()
        source = newSource
    }

    func stop() {
        pendingScan?.cancel()
        pendingScan = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func scheduleScan(directory: URL) {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scan(directory: directory)
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func scan(directory: URL) {
        let current = Self.snapshot(of: directory)
        let added = current.subtracting(known)
        known = current
        guard let newest = added.sorted().first,
              Date().timeIntervalSince(lastReport) > 90 else { return }
        lastReport = Date()
        onNewFile?(newest)
    }

    private static func snapshot(of directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            let ext = (name as NSString).pathExtension.lowercased()
            return !ignoredExtensions.contains(ext)
        })
    }
}
