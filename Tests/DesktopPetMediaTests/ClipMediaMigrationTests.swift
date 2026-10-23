import XCTest
import AppKit
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
