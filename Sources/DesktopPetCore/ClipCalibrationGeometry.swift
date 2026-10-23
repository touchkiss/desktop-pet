import CoreGraphics
import Foundation

/// Shared viewport geometry; never fit the two images independently.
public enum ClipCalibrationGeometry {
    public static let baseline: CGFloat = 28

    public static func fitScale(current: CGSize, reference: CGSize, canvas: CGSize) -> CGFloat {
        guard PetClipPresentationPolicy.isValidDisplaySize(canvas) else { return 1 }
        let sizes = [current, reference].filter(PetClipPresentationPolicy.isValidDisplaySize)
        guard let width = sizes.map(\.width).max(), let height = sizes.map(\.height).max() else { return 1 }
        return max(0.001, min(max(1, canvas.width - 48) / width, max(1, canvas.height - baseline - 24) / height))
    }

    public static func imageRect(
        size: CGSize, canvas: CGSize, scale: CGFloat, offset: CGPoint = .zero
    ) -> CGRect {
        guard PetClipPresentationPolicy.isValidDisplaySize(size),
              PetClipPresentationPolicy.isValidDisplaySize(canvas),
              scale.isFinite, scale > 0, offset.x.isFinite, offset.y.isFinite else { return .zero }
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        guard PetClipPresentationPolicy.isValidDisplaySize(drawn) else { return .zero }
        return CGRect(x: (canvas.width - drawn.width) / 2 + offset.x,
                      y: baseline + offset.y, width: drawn.width, height: drawn.height)
    }

    public static func referenceID(preferred: String?, available: [String]) -> String? {
        if let preferred, available.contains(preferred) { return preferred }
        return available.first
    }

    public static func parsedClipScale(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
        return PetClipPresentationPolicy.clampedClipScale(value)
    }
}
