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

public enum ClipMoveDirection: Sendable {
    case up
    case down
}

public struct ClipMoveResult: Equatable, Sendable {
    public let orderedIDs: [String]
    public let selectedIDs: [String]

    public init(orderedIDs: [String], selectedIDs: [String]) {
        self.orderedIDs = orderedIDs
        self.selectedIDs = selectedIDs
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

    public static func resolvedClipScale(_ storedValue: Double?) -> Double {
        clampedClipScale(storedValue ?? defaultClipScale)
    }

    public static func effectiveScale(clipScale: Double, globalScale: Double) -> Double {
        let safeGlobal = globalScale.isFinite
            ? min(maximumGlobalScale, max(minimumGlobalScale, globalScale))
            : 1.0
        return clampedClipScale(clipScale) * safeGlobal
    }

    public static func scaleSummary(clipScale: Double, globalScale: Double) -> String {
        let clip = clampedClipScale(clipScale)
        let global = globalScale.isFinite
            ? min(maximumGlobalScale, max(minimumGlobalScale, globalScale))
            : 1.0
        return String(
            format: "片段 %.2f× × 全局 %.2f× = %.2f×",
            locale: Locale(identifier: "en_US_POSIX"),
            clip,
            global,
            clip * global
        )
    }

    public static func displaySize(
        width: Int,
        height: Int,
        clipScale: Double,
        globalScale: Double,
        presentationMultiplier: Double = 1
    ) -> CGSize {
        guard width > 0, height > 0 else { return .zero }
        let normalScale = effectiveScale(clipScale: clipScale, globalScale: globalScale)
        let extraScale = presentationMultiplier.isFinite ? max(1, presentationMultiplier) : 1
        let size = CGSize(
            width: CGFloat(width) * normalScale * extraScale,
            height: CGFloat(height) * normalScale * extraScale
        )
        return isValidDisplaySize(size) ? size : .zero
    }

    public static func isValidDisplaySize(_ size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }

    public static func visibleIDs(
        from entries: [ClipLibraryEntry],
        in tab: ClipLibraryTab
    ) -> [String] {
        entries.compactMap { entry in
            switch tab {
            case .cats:
                return entry.isCursorPrey ? nil : entry.id
            case .cursorTargets:
                return entry.isCursorPrey ? entry.id : nil
            }
        }
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

    public static func replacingVisibleOrder(
        in allIDs: [String],
        visibleIDs: [String],
        reorderedVisibleIDs: [String]
    ) -> [String] {
        guard visibleIDs.count == reorderedVisibleIDs.count,
              Set(visibleIDs) == Set(reorderedVisibleIDs) else {
            return allIDs
        }
        let visibleSet = Set(visibleIDs)
        var replacements = reorderedVisibleIDs.makeIterator()
        return allIDs.map { id in
            guard visibleSet.contains(id) else { return id }
            return replacements.next() ?? id
        }
    }
}
