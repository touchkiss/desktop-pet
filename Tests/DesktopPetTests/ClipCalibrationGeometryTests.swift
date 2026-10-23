import XCTest
@testable import DesktopPetCore

final class ClipCalibrationGeometryTests: XCTestCase {
    func testCommonScalePreservesRelativeDisplaySize() {
        let canvas = CGSize(width: 400, height: 320)
        let current = CGSize(width: 200, height: 100)
        let reference = CGSize(width: 100, height: 200)
        let scale = ClipCalibrationGeometry.fitScale(current: current, reference: reference, canvas: canvas)
        let a = ClipCalibrationGeometry.imageRect(size: current, canvas: canvas, scale: scale)
        let b = ClipCalibrationGeometry.imageRect(size: reference, canvas: canvas, scale: scale)
        XCTAssertEqual(a.width / b.width, 2, accuracy: 0.0001)
        XCTAssertEqual(a.height / b.height, 0.5, accuracy: 0.0001)
        XCTAssertEqual(a.minY, b.minY)
        XCTAssertEqual(a.midX, canvas.width / 2)
        XCTAssertLessThanOrEqual(max(a.maxY, b.maxY), canvas.height)
    }

    func testEditingSizeWithFixedViewportDoesNotRefit() {
        let canvas = CGSize(width: 400, height: 320)
        let first = CGSize(width: 100, height: 100)
        let scale = ClipCalibrationGeometry.fitScale(current: first, reference: first, canvas: canvas)
        let before = ClipCalibrationGeometry.imageRect(size: first, canvas: canvas, scale: scale)
        let after = ClipCalibrationGeometry.imageRect(size: CGSize(width: 200, height: 200), canvas: canvas, scale: scale)
        XCTAssertEqual(after.width, before.width * 2)
        XCTAssertEqual(after.minY, before.minY)
    }

    func testDragOffsetMovesOnlyPosition() {
        let canvas = CGSize(width: 400, height: 320)
        let size = CGSize(width: 100, height: 150)
        let base = ClipCalibrationGeometry.imageRect(size: size, canvas: canvas, scale: 1)
        let moved = ClipCalibrationGeometry.imageRect(size: size, canvas: canvas, scale: 1, offset: CGPoint(x: 15, y: -9))
        XCTAssertEqual(moved.size, base.size)
        XCTAssertEqual(moved.minX, base.minX + 15)
        XCTAssertEqual(moved.minY, base.minY - 9)
    }

    func testInvalidSizesCannotProduceInvalidGeometry() {
        let canvas = CGSize(width: 400, height: 320)
        XCTAssertEqual(ClipCalibrationGeometry.imageRect(size: .zero, canvas: canvas, scale: 1), .zero)
        XCTAssertEqual(ClipCalibrationGeometry.imageRect(size: canvas, canvas: canvas, scale: .nan), .zero)
        XCTAssertEqual(ClipCalibrationGeometry.fitScale(current: .zero, reference: .zero, canvas: canvas), 1)
        XCTAssertEqual(ClipCalibrationGeometry.fitScale(current: canvas, reference: canvas, canvas: .zero), 1)
    }

    func testReferenceFallbackKeepsExistingChoiceAndHandlesDeletion() {
        XCTAssertEqual(ClipCalibrationGeometry.referenceID(preferred: "b", available: ["a", "b"]), "b")
        XCTAssertEqual(ClipCalibrationGeometry.referenceID(preferred: "deleted", available: ["a", "b"]), "a")
        XCTAssertNil(ClipCalibrationGeometry.referenceID(preferred: "b", available: []))
    }

    func testScaleInputRejectsInvalidValuesAndClampsValidOnes() {
        XCTAssertEqual(ClipCalibrationGeometry.parsedClipScale(" 0.85 "), 0.85)
        XCTAssertEqual(ClipCalibrationGeometry.parsedClipScale("9"), 3)
        XCTAssertEqual(ClipCalibrationGeometry.parsedClipScale("0.01"), 0.25)
        for text in ["", "abc", "nan", "inf", "-inf"] {
            XCTAssertNil(ClipCalibrationGeometry.parsedClipScale(text))
        }
    }
}
