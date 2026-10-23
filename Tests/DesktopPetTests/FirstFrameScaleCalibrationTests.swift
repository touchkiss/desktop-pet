import XCTest
@testable import DesktopPetCore

final class FirstFrameScaleCalibrationTests: XCTestCase {
    private func silhouette(width: Int = 40, height: Int = 40, rect: CGRect, display: CGSize) -> FirstFrameSilhouette? {
        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width where rect.contains(CGPoint(x: x, y: y)) { alpha[y * width + x] = 255 }
        }
        return FirstFrameSilhouette(alpha: alpha, width: width, height: height, displaySize: display)
    }

    func testSameSubjectWithDifferentPaddingProducesAbsoluteScale() throws {
        let reference = try XCTUnwrap(silhouette(rect: CGRect(x: 10, y: 10, width: 20, height: 20), display: CGSize(width: 200, height: 200)))
        let target = try XCTUnwrap(silhouette(rect: CGRect(x: 5, y: 5, width: 30, height: 30), display: CGSize(width: 200, height: 200)))
        let result = FirstFrameScaleCalibration.suggestion(reference: reference, referenceScale: 1.2, target: target)
        XCTAssertEqual(try XCTUnwrap(result.scale), 0.8, accuracy: 0.0001)
        XCTAssertNil(result.issue)
        XCTAssertEqual(reference.displayArea, 10000, accuracy: 0.001)
    }

    func testDifferentRasterResolutionsHaveSamePhysicalArea() throws {
        let a = try XCTUnwrap(silhouette(rect: CGRect(x: 10, y: 10, width: 20, height: 20), display: CGSize(width: 200, height: 200)))
        let b = try XCTUnwrap(silhouette(width: 80, height: 80, rect: CGRect(x: 20, y: 20, width: 40, height: 40), display: CGSize(width: 200, height: 200)))
        XCTAssertEqual(a.displayArea, b.displayArea)
        XCTAssertEqual(FirstFrameScaleCalibration.suggestion(reference: a, referenceScale: 0.9, target: b).scale, 0.9)
    }

    func testDetachedNoiseDoesNotChangeMainSubject() throws {
        var alpha = [UInt8](repeating: 0, count: 1600)
        for y in 10..<30 { for x in 10..<30 { alpha[y * 40 + x] = 255 } }
        alpha[0] = 255
        let subject = try XCTUnwrap(FirstFrameSilhouette(alpha: alpha, width: 40, height: 40, displaySize: CGSize(width: 200, height: 200)))
        XCTAssertEqual(subject.displayArea, 10000)
    }

    func testTransparentMalformedAndTinySubjectsAreRejected() {
        XCTAssertNil(FirstFrameSilhouette(alpha: [0], width: 40, height: 40, displaySize: CGSize(width: 200, height: 200)))
        XCTAssertNil(FirstFrameSilhouette(alpha: [UInt8](repeating: 0, count: 1600), width: 40, height: 40, displaySize: CGSize(width: 200, height: 200)))
        XCTAssertNil(silhouette(rect: CGRect(x: 1, y: 1, width: 2, height: 2), display: CGSize(width: 200, height: 200)))
        XCTAssertNil(silhouette(rect: CGRect(x: 10, y: 10, width: 20, height: 20), display: .zero))
    }

    func testDifferentPoseAndOutOfRangeAreSkipped() throws {
        let reference = try XCTUnwrap(silhouette(rect: CGRect(x: 10, y: 10, width: 20, height: 20), display: CGSize(width: 200, height: 200)))
        let wide = try XCTUnwrap(silhouette(rect: CGRect(x: 2, y: 15, width: 35, height: 10), display: CGSize(width: 200, height: 200)))
        XCTAssertEqual(FirstFrameScaleCalibration.suggestion(reference: reference, referenceScale: 1, target: wide).issue, .differentShape)
        let tinyDisplay = try XCTUnwrap(silhouette(rect: CGRect(x: 10, y: 10, width: 20, height: 20), display: CGSize(width: 20, height: 20)))
        XCTAssertEqual(FirstFrameScaleCalibration.suggestion(reference: reference, referenceScale: 1, target: tinyDisplay).issue, .outOfRange)
        XCTAssertNil(FirstFrameScaleCalibration.suggestion(reference: reference, referenceScale: .nan, target: reference).scale)
    }

    func testEqualBoundsButDifferentSilhouetteIsRejected() throws {
        let square = try XCTUnwrap(silhouette(rect: CGRect(x: 10, y: 10, width: 20, height: 20), display: CGSize(width: 200, height: 200)))
        var alpha = [UInt8](repeating: 0, count: 1600)
        for y in 10..<30 { for x in 10..<30 where x < 14 || y < 14 { alpha[y * 40 + x] = 255 } }
        let lShape = try XCTUnwrap(FirstFrameSilhouette(alpha: alpha, width: 40, height: 40, displaySize: CGSize(width: 200, height: 200)))
        XCTAssertEqual(FirstFrameScaleCalibration.suggestion(reference: square, referenceScale: 1, target: lShape).issue, .differentShape)
    }
}
