import Foundation
import CoreGraphics

/// Largest opaque component expressed in unscaled display points, independent of PNG resolution.
public struct FirstFrameSilhouette: Sendable {
    public let displayArea: Double
    public let aspectRatio: Double
    private let mask: [Bool]

    public init?(alpha: [UInt8], width: Int, height: Int, displaySize: CGSize) {
        guard width > 0, height > 0, width <= 512, height <= 512,
              alpha.count == width * height,
              PetClipPresentationPolicy.isValidDisplaySize(displaySize) else { return nil }
        var visited = [Bool](repeating: false, count: alpha.count)
        var largest: [Int] = []
        for seed in alpha.indices where !visited[seed] && alpha[seed] >= 64 {
            var component = [seed]
            visited[seed] = true
            var cursor = 0
            while cursor < component.count {
                let index = component[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let next = ny * width + nx
                        if !visited[next] && alpha[next] >= 64 {
                            visited[next] = true
                            component.append(next)
                        }
                    }
                }
            }
            if component.count > largest.count { largest = component }
        }
        guard largest.count >= 16 else { return nil }
        var minX = width, maxX = 0, minY = height, maxY = 0
        var subject = [Bool](repeating: false, count: alpha.count)
        for index in largest {
            subject[index] = true
            minX = min(minX, index % width)
            maxX = max(maxX, index % width)
            minY = min(minY, index / width)
            maxY = max(maxY, index / width)
        }
        let subjectWidth = maxX - minX + 1
        let subjectHeight = maxY - minY + 1
        let pointWidth = displaySize.width / Double(width)
        let pointHeight = displaySize.height / Double(height)
        displayArea = Double(largest.count) * pointWidth * pointHeight
        aspectRatio = Double(subjectWidth) * pointWidth / (Double(subjectHeight) * pointHeight)
        guard displayArea.isFinite, displayArea > 0, aspectRatio.isFinite else { return nil }
        var normalized: [Bool] = []
        for y in 0..<32 {
            for x in 0..<32 {
                let sx = min(maxX, minX + Int((Double(x) + 0.5) * Double(subjectWidth) / 32))
                let sy = min(maxY, minY + Int((Double(y) + 0.5) * Double(subjectHeight) / 32))
                normalized.append(subject[sy * width + sx])
            }
        }
        mask = normalized
    }

    public func similarity(to other: FirstFrameSilhouette) -> Double {
        var intersection = 0, union = 0
        for index in mask.indices {
            if mask[index] || other.mask[index] { union += 1 }
            if mask[index] && other.mask[index] { intersection += 1 }
        }
        return union > 0 ? Double(intersection) / Double(union) : 0
    }
}

public enum FirstFrameScaleIssue: String, Sendable {
    case differentShape = "首帧轮廓差异较大，请手动标定"
    case outOfRange = "建议倍率超出 0.25–3.00，已跳过"
    case invalidReference = "参照倍率无效"
}

public struct FirstFrameScaleSuggestion: Sendable {
    public let scale: Double?
    public let issue: FirstFrameScaleIssue?
}

public enum FirstFrameScaleCalibration {
    public static func suggestion(
        reference: FirstFrameSilhouette, referenceScale: Double, target: FirstFrameSilhouette
    ) -> FirstFrameScaleSuggestion {
        guard referenceScale.isFinite,
              (PetClipPresentationPolicy.minimumClipScale...PetClipPresentationPolicy.maximumClipScale).contains(referenceScale) else {
            return FirstFrameScaleSuggestion(scale: nil, issue: .invalidReference)
        }
        guard abs(log(reference.aspectRatio / target.aspectRatio)) <= log(1.15),
              reference.similarity(to: target) >= 0.8 else {
            return FirstFrameScaleSuggestion(scale: nil, issue: .differentShape)
        }
        let scale = referenceScale * sqrt(reference.displayArea / target.displayArea)
        guard scale.isFinite,
              (PetClipPresentationPolicy.minimumClipScale...PetClipPresentationPolicy.maximumClipScale).contains(scale) else {
            return FirstFrameScaleSuggestion(scale: nil, issue: .outOfRange)
        }
        return FirstFrameScaleSuggestion(scale: scale, issue: nil)
    }
}
