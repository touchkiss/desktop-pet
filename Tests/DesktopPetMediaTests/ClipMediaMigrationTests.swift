import XCTest
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import DesktopPet

final class ClipMediaMigrationTests: XCTestCase {
    func testMigrationRetainsEndpointsAndBackupAndCanRepeat() async throws {
        try await Task.detached {
            let directory = try Self.fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let clip = Self.clip()
            let first = try Data(contentsOf: directory.appendingPathComponent("frames/00001.png"))
            try ClipMediaMigration.convert(clip, keepBackup: true, directory: directory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("animation.mov").path))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("frames").path)), ["00001.png", "00003.png"])
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("frames/00001.png")), first)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("png-backup/00002.png").path))
            try ClipMediaMigration.convert(clip, keepBackup: true, directory: directory)
        }.value
    }

    func testNewImportDoesNotRetainIntermediatePNG() async throws {
        try await Task.detached {
            let directory = try Self.fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            try ClipMediaMigration.convert(Self.clip(), keepBackup: false, directory: directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("png-backup").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("frames/00002.png").path))
        }.value
    }

    func testFailurePreservesOriginalFrames() async throws {
        try await Task.detached {
            let directory = try Self.fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.removeItem(at: directory.appendingPathComponent("frames/00002.png"))
            XCTAssertThrowsError(try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("frames/00001.png").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("animation.mov").path))
        }.value
    }

    func testInterruptedArchiveRecoversEndpointsFromBackup() async throws {
        try await Task.detached {
            let directory = try Self.fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let frames = directory.appendingPathComponent("frames")
            try AlphaVideoEncoder.encode(frameURLs: (1...3).map { frames.appendingPathComponent(String(format: "%05d.png", $0)) }, fps: 24,
                                         outputURL: directory.appendingPathComponent("animation.mov"))
            try FileManager.default.moveItem(at: frames, to: directory.appendingPathComponent("png-backup"))
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: frames.appendingPathComponent("00003.png").path))
        }.value
    }

    func testMissingOrDamagedMovieRecoversFromArchivedSequence() async throws {
        try await Task.detached {
            let directory = try Self.fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let movie = directory.appendingPathComponent("animation.mov")
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
            try FileManager.default.removeItem(at: movie)
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
            try Data("broken movie".utf8).write(to: movie)
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
            let validation = try AlphaVideoEncoder.validate(url: movie, expectedFrameCount: 3, fps: 24)
            XCTAssertEqual(validation.frameCount, 3)
        }.value
    }

    func testRestoredFramesCoexistingWithBackupCanResume() async throws {
        try await Task.detached {
            let directory = try Self.fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let frames = directory.appendingPathComponent("frames")
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
            try FileManager.default.removeItem(at: frames)
            try FileManager.default.copyItem(at: directory.appendingPathComponent("png-backup"), to: frames)
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: frames.path).count, 2)
        }.value
    }

    @MainActor
    func testNativePlaybackClockWaitsAndFinishesOnlyOnceAtLastFrame() async throws {
        let directory = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(libraryURL: directory.appendingPathComponent("library.json"))
        _ = store.update { $0.clips = [Self.clip()] }
        let engine = PlaylistEngine()
        defer { engine.stop() }
        var time = 0.0
        var finished = 0
        engine.playbackTimeProvider = { _ in time }
        engine.clipFinishedHandler = { _ in finished += 1; return false }
        engine.attach(store: store)
        engine.playClip(id: "test")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(engine.currentFrameIndex, 1)
        XCTAssertEqual(finished, 0)
        time = 2.0 / 24
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.currentFrameIndex, 3)
        XCTAssertEqual(finished, 1)
        engine.resumeAfterHold(playNext: false)
        XCTAssertEqual(engine.currentFrameIndex, 1)
    }

    @MainActor
    func testPendingSeekReportsTargetInsteadOfPreviousLoopTime() async throws {
        let directory = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
        }.value
        let video = AlphaVideoPlayback(movieURLForID: { _ in directory.appendingPathComponent("animation.mov") })
        defer { video.stop() }
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertTrue(video.display(id: "test", frame: 3, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        XCTAssertEqual(try XCTUnwrap(video.playbackTime(for: "test")), 2.0 / 24, accuracy: 0.000001)
        XCTAssertTrue(video.display(id: "test", frame: 1, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        XCTAssertEqual(video.playbackTime(for: "test"), 0)
    }

    @MainActor
    func testPowerLifecycleReleasesAndRecreatesPlayerOnlyAfterBothWakeEvents() async throws {
        let center = NotificationCenter()
        let power = PlaybackPowerMonitor(notificationCenter: center)
        let directory = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
        }.value
        var players: [AVPlayer] = []
        let video = AlphaVideoPlayback(movieURLForID: { _ in directory.appendingPathComponent("animation.mov") },
            powerMonitor: power, playerFactory: { let p = AVPlayer(); players.append(p); return p })
        defer { video.stop() }
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertTrue(video.display(id: "test", frame: 2, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        let target = try XCTUnwrap(video.playbackTime(for: "test"))
        XCTAssertTrue(try XCTUnwrap(players.last?.currentItem).outputs.isEmpty)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertTrue(video.isSuspended)
        XCTAssertNil(video.layer.player)
        XCTAssertNil(players[0].currentItem)
        XCTAssertEqual(video.playbackTime(for: "test"), target)
        // Render ticks during display sleep must not recreate media resources.
        XCTAssertTrue(video.display(id: "test", frame: 2, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        XCTAssertEqual(players.count, 1)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertTrue(video.isSuspended)
        XCTAssertEqual(players.count, 1)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertFalse(video.isSuspended)
        XCTAssertEqual(players.count, 2)
        XCTAssertNotNil(video.layer.player)
        XCTAssertEqual(video.playbackTime(for: "test"), target)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(players.count, 2)
    }

    @MainActor
    func testStoppedPlaybackDoesNotResurrectOnWake() async throws {
        let center = NotificationCenter()
        let power = PlaybackPowerMonitor(notificationCenter: center)
        let directory = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
        }.value
        let video = AlphaVideoPlayback(movieURLForID: { _ in directory.appendingPathComponent("animation.mov") }, powerMonitor: power)
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertTrue(video.display(id: "test", frame: 1, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        video.stop()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(video.isActive)
        XCTAssertNil(video.layer.player)
    }

    @MainActor
    func testLongLivedPlayerRenewsAtLoopBoundaryAndDetachesSnapshotOutput() async throws {
        let directory = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
        }.value
        let power = PlaybackPowerMonitor(notificationCenter: NotificationCenter())
        var now = 0.0
        var players: [AVPlayer] = []
        let video = AlphaVideoPlayback(movieURLForID: { _ in directory.appendingPathComponent("animation.mov") },
            powerMonitor: power, playerFactory: { let p = AVPlayer(); players.append(p); return p },
            uptime: { now }, maximumPlayerAge: 10)
        defer { video.stop() }
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertTrue(video.display(id: "test", frame: 1, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        let oldItem = try XCTUnwrap(players[0].currentItem)
        XCTAssertTrue(oldItem.outputs.isEmpty)
        _ = video.snapshot()
        XCTAssertEqual(oldItem.outputs.count, 1)
        now = 11
        XCTAssertTrue(video.display(id: "test", frame: 3, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        XCTAssertEqual(players.count, 1)
        XCTAssertTrue(video.display(id: "test", frame: 1, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        XCTAssertEqual(players.count, 2)
        XCTAssertNil(players[0].currentItem)
        XCTAssertTrue(oldItem.outputs.isEmpty)
        XCTAssertEqual(video.playbackTime(for: "test"), 0)
    }

    @MainActor
    func testPausedSurfaceCreatedDuringSleepRestoresLatestClipWithoutPlaying() async throws {
        let directory = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
        }.value
        let center = NotificationCenter()
        let power = PlaybackPowerMonitor(notificationCenter: center)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        var players: [AVPlayer] = []
        let video = AlphaVideoPlayback(movieURLForID: { _ in directory.appendingPathComponent("animation.mov") },
            powerMonitor: power, playerFactory: { let p = AVPlayer(); players.append(p); return p })
        defer { video.stop() }
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertTrue(video.display(id: "old", frame: 1, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        XCTAssertTrue(video.display(id: "new", frame: 2, frameCount: 3, fps: 24,
                                    playing: false, in: view, rect: view.bounds))
        XCTAssertTrue(players.isEmpty)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(players.count, 1)
        XCTAssertNil(video.playbackTime(for: "old"))
        XCTAssertEqual(try XCTUnwrap(video.playbackTime(for: "new")), 1.0 / 24, accuracy: 0.000001)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(players[0].rate, 0)
        XCTAssertEqual(try XCTUnwrap(video.playbackTime(for: "new")), 1.0 / 24, accuracy: 0.001)
    }

    @MainActor
    func testPlaybackAndPowerObserversReleaseOnDeinit() async throws {
        let directory = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Task.detached {
            try ClipMediaMigration.convert(Self.clip(), keepBackup: true, directory: directory)
        }.value
        let center = NotificationCenter()
        var power: PlaybackPowerMonitor? = PlaybackPowerMonitor(notificationCenter: center)
        weak let weakPower = power
        var player: AVPlayer?
        var video: AlphaVideoPlayback? = AlphaVideoPlayback(movieURLForID: { _ in directory.appendingPathComponent("animation.mov") },
            powerMonitor: power!, playerFactory: { let p = AVPlayer(); player = p; return p })
        weak let weakVideo = video
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertTrue(video!.display(id: "test", frame: 1, frameCount: 3, fps: 24, in: view, rect: view.bounds))
        video = nil
        XCTAssertNil(weakVideo)
        XCTAssertNil(player?.currentItem)
        power = nil
        XCTAssertNil(weakPower)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
    }

    @MainActor
    func testSuspendedEngineDoesNotAdvanceOrFinishHeldFrame() async throws {
        let directory = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(libraryURL: directory.appendingPathComponent("library.json"))
        _ = store.update { $0.clips = [Self.clip()] }
        let engine = PlaylistEngine()
        defer { engine.stop() }
        var suspended = true
        var finished = 0
        engine.playbackIsSuspended = { suspended }
        engine.clipFinishedHandler = { _ in finished += 1; return false }
        engine.attach(store: store)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.currentFrameIndex, 1)
        XCTAssertEqual(finished, 0)
        suspended = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.currentFrameIndex, 3)
        XCTAssertEqual(finished, 1)
    }

    func testOddSizeMovieAndPNGExportUseIdenticalCanvas() async throws {
        try await Task.detached {
            let id = "media-test-\(UUID().uuidString)"
            let directory = AppPaths.clipDirectory(id: id)
            defer { try? FileManager.default.removeItem(at: directory) }
            let frames = directory.appendingPathComponent("frames")
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            for i in 1...3 {
                let context = CGContext(data: nil, width: 65, height: 49, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(CGColor(red: CGFloat(i) / 3, green: 0.4, blue: 0, alpha: 0.5))
                context.fill(CGRect(x: 4, y: 4, width: 50, height: 36))
                let url = frames.appendingPathComponent(String(format: "%05d.png", i))
                let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, context.makeImage()!, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            let clip = PetClip(id: id, name: "test", sourcePath: "", frameCount: 3, fps: 23.976,
                displayWidth: 65, displayHeight: 49, firstFingerprint: [], lastFingerprint: [],
                nextClipIDs: [], createdAt: Date())
            try ClipMediaMigration.convert(clip, keepBackup: false)
            for apng in [true, false] {
                let output = directory.appendingPathComponent(apng ? "test.png" : "test.gif")
                XCTAssertTrue(ClipExporter.export(clip: clip, to: output, apng: apng))
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetCount(source), 3)
                for index in 0..<3 {
                    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
                    XCTAssertEqual(image.width, 65)
                    XCTAssertEqual(image.height, 49)
                }
            }
        }.value
    }

    private static func clip() -> PetClip {
        PetClip(id: "test", name: "test", sourcePath: "", frameCount: 3, fps: 24,
                displayWidth: 64, displayHeight: 48, firstFingerprint: [], lastFingerprint: [],
                nextClipIDs: [], createdAt: Date())
    }

    private static func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let frames = directory.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for i in 1...3 {
            let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
            context.fill(CGRect(x: i, y: 4, width: 20, height: 24))
            let url = frames.appendingPathComponent(String(format: "%05d.png", i))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        return directory
    }
}
