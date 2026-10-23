import Foundation
import CoreGraphics
import ImageIO
import DesktopPetCore

enum FirstFrameCalibrationAnalyzer {
    struct Entry: Sendable {
        let id: String
        let name: String
        let originalScale: Double
        let suggestedScale: Double?
        let note: String
    }

    enum AnalysisError: LocalizedError {
        case unreadable
        case noSubject

        var errorDescription: String? {
            switch self {
            case .unreadable: return "首帧缺失或无法读取"
            case .noSubject: return "首帧无有效主体或显示尺寸无效"
            }
        }
    }

    static func silhouette(for clip: PetClip) throws -> FirstFrameSilhouette {
        let url = AppPaths.frameURL(clipID: clip.id, index: 1)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw AnalysisError.unreadable }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw AnalysisError.unreadable }
        let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        guard let result = FirstFrameSilhouette(alpha: alpha, width: width, height: height,
                                              displaySize: CGSize(width: clip.displayWidth, height: clip.displayHeight)) else {
            throw AnalysisError.noSubject
        }
        return result
    }

    static func analyze(reference: PetClip, clips: [PetClip]) throws -> [Entry] {
        let referenceShape = try silhouette(for: reference)
        return clips.filter { $0.libraryTab == .cats && $0.id != reference.id }.map { clip in
            do {
                let shape = try silhouette(for: clip)
                let suggestion = FirstFrameScaleCalibration.suggestion(reference: referenceShape, referenceScale: reference.clipScale, target: shape)
                return Entry(id: clip.id, name: clip.name, originalScale: clip.clipScale,
                             suggestedScale: suggestion.scale, note: suggestion.issue?.rawValue ?? "首帧轮廓匹配")
            } catch {
                return Entry(id: clip.id, name: clip.name, originalScale: clip.clipScale,
                             suggestedScale: nil, note: error.localizedDescription)
            }
        }
    }
}
