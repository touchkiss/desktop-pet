# Material Tabs and Per-Clip Scale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the clip library into cat and cursor-target tabs, classify every import in the chroma-key sheet, and give each cat clip an independent scale multiplied by the existing global scale.

**Architecture:** Put deterministic clamping, size calculation, tab filtering, and filtered-list ordering in `DesktopPetCore`. Keep persisted clip metadata and AppKit UI in `DesktopPet`, using clip IDs rather than filtered row indices for every mutation. Reuse the existing `cursorPrey` tag and `CursorPreySettings`; add only one backward-compatible cat-scale field.

**Tech Stack:** Swift 5.9, Swift Package Manager, AppKit, Foundation/CoreGraphics, XCTest.

## Global Constraints

- Target macOS 13 and later.
- Independent cat scale range is exactly `0.25×–3.00×`; default is `1.00×`.
- Existing global scale range remains `0.40×–2.20×`.
- Final cat scale is `clipScale × petScale`.
- `cursorPrey` clips use only `CursorPreySettings.displaySize` and never use cat/global scale.
- Existing uncommitted changes in overlapping source files are user-owned: preserve them and do not stage or commit them automatically.
- Do not regenerate keyed PNG frames when changing a material type or scale.

---

## File Map

- Create `Sources/DesktopPetCore/PetClipPresentationPolicy.swift`: deterministic scale, tab filtering, and filtered-order operations.
- Create `Tests/DesktopPetTests/PetClipPresentationPolicyTests.swift`: policy boundary and ordering coverage.
- Modify `Sources/DesktopPet/Models.swift`: persisted per-clip scale, material-tab projection, effective display-size helper.
- Modify `Sources/DesktopPet/ChromaKeySettings.swift`: import material type and accepted preview result.
- Modify `Sources/DesktopPet/ChromaKeyPreviewController.swift`: material selector and richer modal result.
- Modify `Sources/DesktopPet/LibraryStore.swift`: import-role assignment, clip-scale persistence, ID-based filtered ordering.
- Modify `Sources/DesktopPet/LibraryWindowController.swift`: two tabs, filtered ID mapping, import routing, and cat scale editor.
- Modify `Sources/DesktopPet/PetWindowController.swift`: use effective per-clip display size on every refresh, including cache hits.
- Modify `Sources/DesktopPet/TeleportController.swift`: use the same effective display size for landing geometry.
- Modify `Sources/DesktopPet/AppDelegate.swift`: pass the explicit default cat material type for sample bootstrap if the import API requires it.

### Task 1: Deterministic Presentation and Filtered-List Policy

**Files:**
- Create: `Sources/DesktopPetCore/PetClipPresentationPolicy.swift`
- Create: `Tests/DesktopPetTests/PetClipPresentationPolicyTests.swift`

**Interfaces:**
- Produces: `ClipLibraryTab`, `ClipLibraryEntry`, `ClipImportMaterialType`, and `PetClipPresentationPolicy`.
- Produces: `clampedClipScale(_:)`, `effectiveScale(clipScale:globalScale:)`, `displaySize(width:height:clipScale:globalScale:)`, `visibleIDs(from:in:)`, and `moveVisibleIDs(_:selectedIDs:direction:)`.

- [ ] **Step 1: Write failing scale and tab-filter tests**

```swift
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
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter PetClipPresentationPolicyTests`

Expected: compilation fails because `PetClipPresentationPolicy`, `ClipLibraryEntry`, and `ClipLibraryTab` do not exist.

- [ ] **Step 3: Implement the minimal scale and filter policy**

```swift
import CoreGraphics
import Foundation

public enum ClipLibraryTab: Int, CaseIterable, Sendable {
    case cats
    case cursorTargets
}

public enum ClipImportMaterialType: Int, Sendable {
    case cat
    case cursorPrey

    public var isCursorPrey: Bool { self == .cursorPrey }
}

public struct ClipLibraryEntry: Equatable, Sendable {
    public let id: String
    public let isCursorPrey: Bool

    public init(id: String, isCursorPrey: Bool) {
        self.id = id
        self.isCursorPrey = isCursorPrey
    }
}

public enum PetClipPresentationPolicy {
    public static let minimumClipScale = 0.25
    public static let maximumClipScale = 3.0
    public static let defaultClipScale = 1.0
    public static let minimumGlobalScale = 0.4
    public static let maximumGlobalScale = 2.2

    public static func clampedClipScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return defaultClipScale }
        return min(maximumClipScale, max(minimumClipScale, scale))
    }

    public static func effectiveScale(clipScale: Double, globalScale: Double) -> Double {
        let safeGlobal = globalScale.isFinite
            ? min(maximumGlobalScale, max(minimumGlobalScale, globalScale))
            : 1.0
        return clampedClipScale(clipScale) * safeGlobal
    }

    public static func displaySize(
        width: Int,
        height: Int,
        clipScale: Double,
        globalScale: Double
    ) -> CGSize {
        let scale = effectiveScale(clipScale: clipScale, globalScale: globalScale)
        return CGSize(width: CGFloat(max(0, width)) * scale, height: CGFloat(max(0, height)) * scale)
    }

    public static func visibleIDs(from entries: [ClipLibraryEntry], in tab: ClipLibraryTab) -> [String] {
        entries.compactMap { entry in
            switch tab {
            case .cats: return entry.isCursorPrey ? nil : entry.id
            case .cursorTargets: return entry.isCursorPrey ? entry.id : nil
            }
        }
    }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `swift test --filter PetClipPresentationPolicyTests`

Expected: all three tests pass.

- [ ] **Step 5: Add a failing filtered-order test**

```swift
func testMovingVisibleItemSwapsOnlyVisibleSlots() {
    let result = PetClipPresentationPolicy.moveVisibleIDs(
        ["cat-a", "prey", "cat-b"],
        selectedIDs: ["cat-b"],
        direction: .up
    )
    XCTAssertEqual(result.orderedIDs, ["cat-b", "prey", "cat-a"])
    XCTAssertEqual(result.selectedIDs, ["cat-b"])
}
```

- [ ] **Step 6: Run the focused test and verify the expected missing-API failure**

Run: `swift test --filter PetClipPresentationPolicyTests/testMovingVisibleItemSwapsOnlyVisibleSlots`

Expected: compilation fails because `moveVisibleIDs` and its direction/result types do not exist.

- [ ] **Step 7: Implement ID-based visible-slot ordering**

```swift
public enum ClipMoveDirection: Sendable {
    case up
    case down
}

public struct ClipMoveResult: Equatable, Sendable {
    public let orderedIDs: [String]
    public let selectedIDs: [String]
}

public static func moveVisibleIDs(
    _ visibleIDs: [String],
    selectedIDs: [String],
    direction: ClipMoveDirection
) -> ClipMoveResult {
    var ordered = visibleIDs
    let selected = Set(selectedIDs)
    let indices = ordered.indices.filter { selected.contains(ordered[$0]) }
    switch direction {
    case .up:
        for index in indices where index > 0 && !selected.contains(ordered[index - 1]) {
            ordered.swapAt(index, index - 1)
        }
    case .down:
        for index in indices.reversed()
        where index + 1 < ordered.count && !selected.contains(ordered[index + 1]) {
            ordered.swapAt(index, index + 1)
        }
    }
    return ClipMoveResult(
        orderedIDs: ordered,
        selectedIDs: ordered.filter(selected.contains)
    )
}
```

`LibraryStore` will later write these reordered visible IDs back into only the corresponding slots in the full clip array.

- [ ] **Step 8: Run policy tests and verify GREEN**

Run: `swift test --filter PetClipPresentationPolicyTests`

Expected: all policy tests pass with no warnings.

- [ ] **Step 9: Record the checkpoint without committing user-owned changes**

Run: `git diff --check -- Sources/DesktopPetCore/PetClipPresentationPolicy.swift Tests/DesktopPetTests/PetClipPresentationPolicyTests.swift`

Expected: no whitespace errors.

### Task 2: Backward-Compatible Clip Metadata and Import Classification

**Files:**
- Modify: `Sources/DesktopPetCore/PetClipPresentationPolicy.swift`
- Modify: `Tests/DesktopPetTests/PetClipPresentationPolicyTests.swift`
- Modify: `Sources/DesktopPet/Models.swift`
- Modify: `Sources/DesktopPet/ChromaKeySettings.swift`
- Modify: `Sources/DesktopPet/ChromaKeyPreviewController.swift`
- Modify: `Sources/DesktopPet/LibraryStore.swift`
- Modify: `Sources/DesktopPet/AppDelegate.swift`

**Interfaces:**
- Consumes: `PetClipPresentationPolicy` and `ClipLibraryTab` from Task 1.
- Produces: `PetClip.clipScale: Double`, `PetClip.libraryTab`, `PetClip.effectiveDisplaySize(globalScale:)`.
- Produces: `ClipImportMaterialType.cat`, `ClipImportMaterialType.cursorPrey`, and `ChromaKeyPreviewResult`.
- Changes: `commitImport(staging:settings:materialType:)` with `.cat` as the default.

- [ ] **Step 1: Add a failing persisted-value fallback test**

```swift
func testMissingPersistedClipScaleUsesDefault() {
    XCTAssertEqual(PetClipPresentationPolicy.resolvedClipScale(nil), 1.0)
    XCTAssertEqual(PetClipPresentationPolicy.resolvedClipScale(.some(.nan)), 1.0)
    XCTAssertEqual(PetClipPresentationPolicy.resolvedClipScale(0.1), 0.25)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter PetClipPresentationPolicyTests/testMissingPersistedClipScaleUsesDefault`

Expected: compilation fails because `resolvedClipScale` is not implemented.

- [ ] **Step 3: Implement persisted clip scale in `PetClip`**

Add `clipScale` to `CodingKeys`, the memberwise initializer with a default of `1.0`, decoding via `decodeIfPresent(Double.self, forKey:) ?? defaultClipScale`, and encoding via the clamped value. Add:

```swift
var libraryTab: ClipLibraryTab {
    tags.contains(ClipTag.cursorPrey) ? .cursorTargets : .cats
}

func effectiveDisplaySize(globalScale: Double) -> CGSize {
    PetClipPresentationPolicy.displaySize(
        width: displayWidth,
        height: displayHeight,
        clipScale: clipScale,
        globalScale: globalScale
    )
}
```

Normalize the memberwise initializer and decoder with `clampedClipScale` so all in-memory instances are valid.

First add the exact core helper used by decoding:

```swift
public static func resolvedClipScale(_ storedValue: Double?) -> Double {
    clampedClipScale(storedValue ?? defaultClipScale)
}
```

Then decode with `PetClipPresentationPolicy.resolvedClipScale(try c.decodeIfPresent(Double.self, forKey: .clipScale))`.

- [ ] **Step 4: Implement the import result and selector**

In `ChromaKeySettings.swift`, add:

```swift
struct ChromaKeyPreviewResult: Sendable {
    let settings: ChromaKeySettings
    let materialType: ClipImportMaterialType
}
```

Change `ChromaKeyPreviewController.runModal` to return `ChromaKeyPreviewResult?`, add a two-segment material selector labeled “猫猫” and “鼠标互动目标素材”, default it to `.cat`, and return both values from `acceptImport`.

- [ ] **Step 5: Apply the import role atomically in `LibraryStore`**

Change `commitImport` to accept `materialType: ClipImportMaterialType = .cat`. Before appending the new clip, set:

```swift
if materialType == .cursorPrey {
    clip.tags.removeAll { $0 == ClipTag.cursorInteraction }
    clip.tags.append(ClipTag.cursorPrey)
    clip.cursorPreySettings = CursorPreySettings()
}
```

Add `setClipScale(clipID:scale:)`, clamp the value, save once, and keep the existing notification ownership in the controller. Leave sample bootstrap as `.cat` explicitly or via the default argument.

- [ ] **Step 6: Update import call sites and verify build**

Use `result.settings` and `result.materialType` in `LibraryWindowController`; use the existing default for sample bootstrap in `AppDelegate`.

Run: `swift build`

Expected: build succeeds with no warnings.

- [ ] **Step 7: Run all tests and record the checkpoint**

Run: `swift test`

Expected: all tests pass.

Run: `git diff --check -- Sources/DesktopPet/Models.swift Sources/DesktopPet/ChromaKeySettings.swift Sources/DesktopPet/ChromaKeyPreviewController.swift Sources/DesktopPet/LibraryStore.swift Sources/DesktopPet/AppDelegate.swift`

Expected: no whitespace errors.

### Task 3: Two Filtered Library Tabs with Safe ID Mapping

**Files:**
- Modify: `Sources/DesktopPet/LibraryWindowController.swift`
- Modify: `Sources/DesktopPet/LibraryStore.swift`

**Interfaces:**
- Consumes: `PetClip.libraryTab`, `ClipLibraryTab`, and Task 1 ordering policy.
- Produces: controller-local `selectedTab`, `visibleClips`, and `visibleClipIDs` projections.
- Produces: `LibraryStore.moveVisibleClips(ids:selectedIDs:direction:) -> [String]`.

- [ ] **Step 1: Add ordering coverage for multi-selection and boundaries**

```swift
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
```

- [ ] **Step 2: Run ordering tests and verify RED for uncovered behavior**

Run: `swift test --filter PetClipPresentationPolicyTests`

Expected: all assertions pass if Task 1 is complete; if one fails, correct only the ordering policy before continuing.

- [ ] **Step 3: Complete the ordering policy and verify GREEN**

Implement the same directional traversal as the current `moveClipsUp`/`moveClipsDown`, but operate on visible IDs. Run the focused tests until all pass.

- [ ] **Step 4: Add the Tab control and filtered projections**

Add an `NSSegmentedControl(labels: ["猫猫", "鼠标互动目标素材"], trackingMode: .selectOne, target:action:)` above the table. Add:

```swift
private var selectedTab: ClipLibraryTab = .cats

private var visibleClips: [PetClip] {
    store.state.clips.filter { $0.libraryTab == selectedTab }
}
```

Drive `numberOfRows`, `viewFor`, selected row resolution, `selectClip(id:)`, count labels, and selection restoration from this projection. Every operation must resolve `PetClip.id`; no filtered row index may be used against `store.state.clips`.

- [ ] **Step 5: Make actions tab-safe**

Update select all, delete, export, queue creation, and detail display to use `visibleClips`. Disable or reject “按所选播放”, “清除队列”, “重算衔接”, and queue-only affordances while the target tab is selected. On a role toggle or successful import, switch `selectedTab` to the clip's new `libraryTab`, reload, and select that ID.

For ordering, implement `LibraryStore.moveVisibleClips` by replacing only full-array slots occupied by the supplied visible IDs:

```swift
@discardableResult
func moveVisibleClips(
    ids: [String],
    selectedIDs: [String],
    direction: ClipMoveDirection
) -> [String] {
    let result = PetClipPresentationPolicy.moveVisibleIDs(
        ids,
        selectedIDs: selectedIDs,
        direction: direction
    )
    update { state in
        let clipsByID = Dictionary(uniqueKeysWithValues: state.clips.map { ($0.id, $0) })
        var replacements = result.orderedIDs.makeIterator()
        let visibleSet = Set(ids)
        for index in state.clips.indices where visibleSet.contains(state.clips[index].id) {
            guard let replacementID = replacements.next(), let clip = clipsByID[replacementID] else { continue }
            state.clips[index] = clip
        }
        if !state.activeQueue.isEmpty {
            let queued = Set(state.activeQueue)
            state.activeQueue = state.clips.map(\.id).filter(queued.contains)
        }
    }
    return result.selectedIDs
}
```

This keeps interleaved clips in the other Tab fixed.

- [ ] **Step 6: Route successful imports to the correct Tab**

After `commitImport`:

```swift
selectedTab = clip.libraryTab
reload()
selectClip(id: clip.id)
if clip.libraryTab == .cats {
    engine.playClip(id: clip.id)
}
```

Do not change the Tab on cancel or failure.

- [ ] **Step 7: Build and run tests**

Run: `swift test`

Expected: all tests pass.

Run: `swift build`

Expected: the executable builds without warnings.

- [ ] **Step 8: Record the checkpoint without staging overlapping user edits**

Run: `git diff --check -- Sources/DesktopPet/LibraryWindowController.swift Sources/DesktopPet/LibraryStore.swift`

Expected: no whitespace errors.

### Task 4: Cat Scale Editor and Unified Render Geometry

**Files:**
- Modify: `Sources/DesktopPet/LibraryWindowController.swift`
- Modify: `Sources/DesktopPet/LibraryStore.swift`
- Modify: `Sources/DesktopPet/PetWindowController.swift`
- Modify: `Sources/DesktopPet/TeleportController.swift`

**Interfaces:**
- Consumes: `PetClip.effectiveDisplaySize(globalScale:)`.
- Produces: `DetailPanel.onClipScaleChanged: (String, Double) -> Void`.
- Produces: cat detail controls showing clip scale and effective scale.

- [ ] **Step 1: Add effective-scale boundary and new summary-API tests**

```swift
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
```

- [ ] **Step 2: Run the focused tests and verify RED if any boundary is missing**

Run: `swift test --filter PetClipPresentationPolicyTests`

Expected: compilation fails because `scaleSummary` does not exist yet.

- [ ] **Step 3: Implement the summary formatter and verify GREEN**

```swift
public static func scaleSummary(clipScale: Double, globalScale: Double) -> String {
    let clip = clampedClipScale(clipScale)
    let global = globalScale.isFinite
        ? min(maximumGlobalScale, max(minimumGlobalScale, globalScale))
        : 1.0
    let effective = clip * global
    return String(
        format: "片段 %.2f× × 全局 %.2f× = %.2f×",
        locale: Locale(identifier: "en_US_POSIX"),
        clip,
        global,
        effective
    )
}
```

Run: `swift test --filter PetClipPresentationPolicyTests`

Expected: all scale tests pass.

- [ ] **Step 4: Add the cat scale editor**

Pass `store.state.petScale` into `DetailPanel.show`. For clips not tagged `cursorPrey`, add a `0.25...3.00` continuous slider, monospaced clip-scale label, “恢复默认” button, and effective-scale label formatted as:

```text
片段 0.80× × 全局 1.20× = 0.96×
```

Use `PetClipPresentationPolicy.scaleSummary` for the effective-scale label. Update it continuously, call `onClipScaleChanged`, persist through `LibraryStore.setClipScale`, and post `.libraryDidChange` so the desktop window refreshes immediately.

- [ ] **Step 5: Use the shared display-size helper in live playback**

In `PetWindowController.refreshFrame`, compute `let displaySize = clip.effectiveDisplaySize(globalScale: store.state.petScale)` before the frame-cache early return. Apply `petContentSize` and window geometry even when the image itself comes from cache, so slider movement is visible immediately without waiting for the next decoded frame.

- [ ] **Step 6: Use identical geometry for teleport landing**

Replace the local global-only calculation in `TeleportController.placeLandingFrame` with:

```swift
let size = clip.effectiveDisplaySize(globalScale: store.state.petScale)
pet.setTeleportLandingFrame(center: travelTo, size: size)
```

This also covers one-shot `cursorInteraction` cat clips because they remain in the cat Tab and carry their own scale.

- [ ] **Step 7: Run full automated verification**

Run: `swift test`

Expected: all XCTest cases pass.

Run: `swift build`

Expected: debug build succeeds with zero warnings.

- [ ] **Step 8: Perform focused manual verification**

Run: `swift run DesktopPet`

Verify:

1. Existing clips open in the cat Tab and retain their old apparent size at `1.00×`.
2. Importing multiple videos asks for a type on every preview sheet.
3. A target import appears in the target Tab and never starts ordinary playback.
4. A cat import appears in the cat Tab and starts playback.
5. Changing one cat clip's scale updates the desktop immediately and leaves other clips unchanged.
6. Changing global size multiplies the selected clip's scale.
7. Teleport landing does not resize again when the first live frame appears.
8. Reclassifying a clip moves it between Tabs without operating on the wrong row.

- [ ] **Step 9: Final diff hygiene and handoff**

Run: `git diff --check`

Expected: no whitespace errors.

Run: `git status --short`

Expected: pre-existing user changes remain present; newly created and modified files are clearly reported. Do not stage or commit overlapping user-owned source changes unless the user explicitly asks.
