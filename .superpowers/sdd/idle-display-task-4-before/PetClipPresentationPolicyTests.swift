import CoreGraphics
import XCTest
@testable import DesktopPetCore

final class PetClipPresentationPolicyTests: XCTestCase {
    func testClipScaleUsesDefaultForNonFiniteValuesAndClampsBounds() {
        XCTAssertEqual(PetClipPresentationPolicy.clampedClipScale(.nan), 1.0)
        XCTAssertEqual(PetClipPresentationPolicy.clampedClipScale(.infinity), 1.0)
        XCTAssertEqual(PetClipPresentationPolicy.clampedClipScale(0.1), 0.25)
        XCTAssertEqual(PetClipPresentationPolicy.clampedClipScale(4.0), 3.0)
    }

    func testDisplaySizeMultipliesClipAndGlobalScale() {
        let size = PetClipPresentationPolicy.displaySize(
            width: 320,
            height: 200,
            clipScale: 0.8,
            globalScale: 1.2
        )
        XCTAssertEqual(size.width, 307.2, accuracy: 0.0001)
        XCTAssertEqual(size.height, 192.0, accuracy: 0.0001)
    }

    func testTabsSeparateOnlyCursorPreyFromCats() {
        let entries = [
            ClipLibraryEntry(id: "ordinary", isCursorPrey: false),
            ClipLibraryEntry(id: "interaction-cat", isCursorPrey: false),
            ClipLibraryEntry(id: "prey", isCursorPrey: true)
        ]
        XCTAssertEqual(
            PetClipPresentationPolicy.visibleIDs(from: entries, in: .cats),
            ["ordinary", "interaction-cat"]
        )
        XCTAssertEqual(
            PetClipPresentationPolicy.visibleIDs(from: entries, in: .cursorTargets),
            ["prey"]
        )
    }

    func testImportMaterialTypeIdentifiesOnlyCursorTarget() {
        XCTAssertFalse(ClipImportMaterialType.cat.isCursorPrey)
        XCTAssertTrue(ClipImportMaterialType.cursorPrey.isCursorPrey)
    }

    func testMovingVisibleItemChangesOnlyVisibleOrder() {
        let result = PetClipPresentationPolicy.moveVisibleIDs(
            ["cat-a", "cat-b"],
            selectedIDs: ["cat-b"],
            direction: .up
        )
        XCTAssertEqual(result.orderedIDs, ["cat-b", "cat-a"])
        XCTAssertEqual(result.selectedIDs, ["cat-b"])
    }

    func testMissingPersistedClipScaleUsesDefault() {
        XCTAssertEqual(PetClipPresentationPolicy.resolvedClipScale(nil), 1.0)
        XCTAssertEqual(PetClipPresentationPolicy.resolvedClipScale(.some(.nan)), 1.0)
        XCTAssertEqual(PetClipPresentationPolicy.resolvedClipScale(0.1), 0.25)
    }

    func testVisibleMoveHonorsBoundariesAndSelectionBlocks() {
        XCTAssertEqual(
            PetClipPresentationPolicy.moveVisibleIDs(
                ["a", "b", "c"], selectedIDs: ["a"], direction: .up
            ).orderedIDs,
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            PetClipPresentationPolicy.moveVisibleIDs(
                ["a", "b", "c"], selectedIDs: ["c"], direction: .down
            ).orderedIDs,
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            PetClipPresentationPolicy.moveVisibleIDs(
                ["a", "b", "c", "d"], selectedIDs: ["b", "c"], direction: .up
            ).orderedIDs,
            ["b", "c", "a", "d"]
        )
    }

    func testEffectiveScaleUsesExactBoundsAndSafeFallbacks() {
        XCTAssertEqual(
            PetClipPresentationPolicy.effectiveScale(clipScale: 0.25, globalScale: 0.40),
            0.10,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PetClipPresentationPolicy.effectiveScale(clipScale: 3.00, globalScale: 2.20),
            6.60,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PetClipPresentationPolicy.effectiveScale(clipScale: .nan, globalScale: .infinity),
            1.00,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PetClipPresentationPolicy.scaleSummary(clipScale: 0.8, globalScale: 1.2),
            "片段 0.80× × 全局 1.20× = 0.96×"
        )
    }

    func testReplacingVisibleOrderKeepsHiddenSlotsFixed() {
        XCTAssertEqual(
            PetClipPresentationPolicy.replacingVisibleOrder(
                in: ["cat-a", "prey", "cat-b"],
                visibleIDs: ["cat-a", "cat-b"],
                reorderedVisibleIDs: ["cat-b", "cat-a"]
            ),
            ["cat-b", "prey", "cat-a"]
        )
    }
}
