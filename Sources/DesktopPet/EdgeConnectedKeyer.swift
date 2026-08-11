import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Chroma-key that only removes green connected to the image border,
/// so subject interiors (even green-tinted fur) stay opaque.
enum EdgeConnectedKeyer {
    struct Bounds {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int

        var width: Int { max(0, maxX - minX + 1) }
        var height: Int { max(0, maxY - minY + 1) }

        var isEmpty: Bool { maxX < minX || maxY < minY }

        mutating func union(_ other: Bounds) {
            if isEmpty {
                self = other
                return
            }
            if other.isEmpty { return }
            minX = min(minX, other.minX)
            minY = min(minY, other.minY)
            maxX = max(maxX, other.maxX)
            maxY = max(maxY, other.maxY)
        }

        func padded(by pad: Int, width: Int, height: Int) -> Bounds {
            Bounds(
                minX: max(0, minX - pad),
                minY: max(0, minY - pad),
                maxX: min(width - 1, maxX + pad),
                maxY: min(height - 1, maxY + pad)
            )
        }

        /// Convert buffer coords (y=0 at bottom, CGContext native) to CGImage crop rect (y=0 at top).
        func cgCropRect(imageHeight: Int) -> CGRect {
            CGRect(
                x: minX,
                y: imageHeight - 1 - maxY,
                width: width,
                height: height
            )
        }

        static let empty = Bounds(minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min)
    }

    /// Key one RGBA PNG in place (or to another URL). Returns opaque subject bounds
    /// in CGContext buffer coordinates (y = 0 at bottom).
    @discardableResult
    static func keyPNG(
        at inputURL: URL,
        outputURL: URL? = nil,
        settings: ChromaKeySettings
    ) throws -> Bounds {
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ChromaKeyError.invalidVideo
        }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ChromaKeyError.processFailed("无法创建像素缓冲")
        }
        // No Y-flip: keep CGContext native layout (row 0 = bottom). makeImage() preserves orientation.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let count = width * height
        for i in 0..<count {
            let o = i * 4
            let a = pixels[o + 3]
            if a == 0 {
                pixels[o] = 0
                pixels[o + 1] = 0
                pixels[o + 2] = 0
            } else if a < 255 {
                let inv = 255.0 / Double(a)
                pixels[o] = UInt8(min(255, Int(Double(pixels[o]) * inv + 0.5)))
                pixels[o + 1] = UInt8(min(255, Int(Double(pixels[o + 1]) * inv + 0.5)))
                pixels[o + 2] = UInt8(min(255, Int(Double(pixels[o + 2]) * inv + 0.5)))
            }
        }

        let s = settings.clamped()
        let key = parseHex(s.keyHex)
        applyEdgeConnectedKey(
            pixels: &pixels,
            width: width,
            height: height,
            key: key,
            similarity: s.similarity,
            blend: s.blend,
            despillMix: s.despillMix
        )

        let bounds = opaqueBounds(pixels: pixels, width: width, height: height, alphaThreshold: 12)

        for i in 0..<count {
            let o = i * 4
            let a = pixels[o + 3]
            if a == 0 {
                pixels[o] = 0
                pixels[o + 1] = 0
                pixels[o + 2] = 0
            } else if a < 255 {
                pixels[o] = UInt8((Int(pixels[o]) * Int(a) + 127) / 255)
                pixels[o + 1] = UInt8((Int(pixels[o + 1]) * Int(a) + 127) / 255)
                pixels[o + 2] = UInt8((Int(pixels[o + 2]) * Int(a) + 127) / 255)
            }
        }

        guard let outImage = ctx.makeImage() else {
            throw ChromaKeyError.processFailed("无法写出抠图帧")
        }
        try writePNG(outImage, to: outputURL ?? inputURL)
        return bounds
    }

    /// Crop to bounds (buffer coords from `keyPNG`) and scale so the longer side equals `targetMaxSide`.
    static func cropAndNormalizePNG(
        at inputURL: URL,
        outputURL: URL,
        crop: Bounds,
        targetMaxSide: Int
    ) throws -> (width: Int, height: Int) {
        guard !crop.isEmpty else {
            throw ChromaKeyError.noFrames
        }
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ChromaKeyError.invalidVideo
        }

        let srcW = image.width
        let srcH = image.height
        guard crop.minX >= 0, crop.minY >= 0,
              crop.maxX < srcW, crop.maxY < srcH else {
            throw ChromaKeyError.processFailed("裁切范围无效")
        }

        let cropRect = crop.cgCropRect(imageHeight: srcH)
        guard let cropped = image.cropping(to: cropRect) else {
            throw ChromaKeyError.processFailed("裁切失败")
        }

        let cw = crop.width
        let ch = crop.height
        let scale = Double(targetMaxSide) / Double(max(cw, ch))
        let outW = max(1, Int((Double(cw) * scale).rounded()))
        let outH = max(1, Int((Double(ch) * scale).rounded()))

        var outPixels = [UInt8](repeating: 0, count: outW * outH * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &outPixels,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ChromaKeyError.processFailed("无法创建输出缓冲")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let outImage = ctx.makeImage() else {
            throw ChromaKeyError.processFailed("缩放失败")
        }
        try writePNG(outImage, to: outputURL)
        return (outW, outH)
    }

    // MARK: - Core key

    private static func applyEdgeConnectedKey(
        pixels: inout [UInt8],
        width: Int,
        height: Int,
        key: (r: Double, g: Double, b: Double),
        similarity: Double,
        blend: Double,
        despillMix: Double
    ) {
        let count = width * height

        // Prefer the actual border green (real screen often ≠ default hex).
        let sampledKey = sampleBorderKeyColor(pixels: pixels, width: width, height: height) ?? key

        // screenScore ∈ [0,1]: how “green-screen like”. Uses green-dominance first so
        // fur / shadows don’t get pulled in just because chrominance is vaguely close.
        var score = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let o = i * 4
            score[i] = screenScore(
                r: Double(pixels[o]) / 255.0,
                g: Double(pixels[o + 1]) / 255.0,
                b: Double(pixels[o + 2]) / 255.0,
                key: sampledKey
            )
        }

        // Higher similarity → lower bar to count as screen.
        // 0.04 → ~0.42, 0.18 → ~0.28, 0.50 → ~0.08
        let t = min(1, max(0, (similarity - 0.04) / 0.46))
        let minScore = Float(0.42 - t * 0.34)
        var isScreen = [Bool](repeating: false, count: count)
        for i in 0..<count {
            isScreen[i] = score[i] >= minScore
        }

        // Only remove screen that is connected to the frame border.
        var isBG = [Bool](repeating: false, count: count)
        var queue = [Int]()
        queue.reserveCapacity(width + height)

        func trySeed(_ idx: Int) {
            if isScreen[idx], !isBG[idx] {
                isBG[idx] = true
                queue.append(idx)
            }
        }

        for x in 0..<width {
            trySeed(x)
            trySeed((height - 1) * width + x)
        }
        for y in 0..<height {
            trySeed(y * width)
            trySeed(y * width + (width - 1))
        }

        var head = 0
        while head < queue.count {
            let i = queue[head]
            head += 1
            let x = i % width
            let y = i / width
            let neighbors = [
                x > 0 ? i - 1 : -1,
                x + 1 < width ? i + 1 : -1,
                y > 0 ? i - width : -1,
                y + 1 < height ? i + width : -1
            ]
            for n in neighbors where n >= 0 {
                if !isBG[n], isScreen[n] {
                    isBG[n] = true
                    queue.append(n)
                }
            }
        }

        // Eat leftover green speckles that touch confirmed BG — still never through non-screen pixels.
        for _ in 0..<3 {
            var add = [Int]()
            for i in 0..<count where !isBG[i] && isScreen[i] {
                let x = i % width
                let y = i / width
                let touches =
                    (x > 0 && isBG[i - 1]) ||
                    (x + 1 < width && isBG[i + 1]) ||
                    (y > 0 && isBG[i - width]) ||
                    (y + 1 < height && isBG[i + width])
                if touches { add.append(i) }
            }
            if add.isEmpty { break }
            for i in add { isBG[i] = true }
        }

        // Hard key: border-connected screen → fully transparent.
        // Softness only on the FG/BG boundary ring (does not punch holes in the subject).
        let feather = Float(max(0, min(0.4, blend)))
        for i in 0..<count {
            let o = i * 4
            if isBG[i] {
                pixels[o] = 0
                pixels[o + 1] = 0
                pixels[o + 2] = 0
                pixels[o + 3] = 0
                continue
            }

            pixels[o + 3] = 255

            let x = i % width
            let y = i / width
            let nearBG =
                (x > 0 && isBG[i - 1]) ||
                (x + 1 < width && isBG[i + 1]) ||
                (y > 0 && isBG[i - width]) ||
                (y + 1 < height && isBG[i + width])

            if nearBG {
                if feather > 0.001, score[i] > 0.05 {
                    // Soft fringe: more screen-like → more transparent, scaled by blend.
                    let a = 1.0 - Double(min(1, score[i] * (0.55 + feather)))
                    pixels[o + 3] = UInt8(max(0, min(255, Int((a * 255).rounded()))))
                }
                if despillMix > 0 {
                    despillGreen(&pixels, at: o, mix: despillMix)
                }
            }
        }
    }

    /// 0 = not screen, 1 = solid green screen.
    private static func screenScore(
        r: Double, g: Double, b: Double,
        key: (r: Double, g: Double, b: Double)
    ) -> Float {
        let maxRB = max(r, b)
        // Must be green-dominant. Olive fur / warm coats fail this gate.
        let excess = g - maxRB
        if excess < 0.02 { return 0 }

        let excessScore = min(1, excess / 0.35)
        let dist = colorDistance(r, g, b, key.r, key.g, key.b)
        // Typical solid screen vs key is ~0…0.15; far colors → 0.
        let hueScore = max(0, min(1, 1.0 - dist / 0.28))
        // Green-dominance carries more weight than exact key match (screens vary).
        return Float(excessScore * 0.7 + hueScore * 0.3)
    }

    private static func sampleBorderKeyColor(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> (r: Double, g: Double, b: Double)? {
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var n = 0

        func consider(_ idx: Int) {
            let o = idx * 4
            let r = Double(pixels[o]) / 255.0
            let g = Double(pixels[o + 1]) / 255.0
            let b = Double(pixels[o + 2]) / 255.0
            if g > r + 0.04, g > b + 0.04 {
                sumR += r
                sumG += g
                sumB += b
                n += 1
            }
        }

        let step = max(1, width / 80)
        for x in stride(from: 0, to: width, by: step) {
            consider(x)
            consider((height - 1) * width + x)
        }
        for y in stride(from: 0, to: height, by: step) {
            consider(y * width)
            consider(y * width + (width - 1))
        }

        guard n >= 12 else { return nil }
        return (sumR / Double(n), sumG / Double(n), sumB / Double(n))
    }

    private static func despillGreen(_ pixels: inout [UInt8], at o: Int, mix: Double) {
        let r = Double(pixels[o])
        let g = Double(pixels[o + 1])
        let b = Double(pixels[o + 2])
        let maxRB = max(r, b)
        if g > maxRB {
            let target = maxRB
            let ng = g * (1.0 - mix) + target * mix
            pixels[o + 1] = UInt8(max(0, min(255, Int(ng.rounded()))))
        }
    }

    private static func colorDistance(
        _ r: Double, _ g: Double, _ b: Double,
        _ kr: Double, _ kg: Double, _ kb: Double
    ) -> Double {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let ky = 0.299 * kr + 0.587 * kg + 0.114 * kb
        let u = 0.492 * (b - y)
        let v = 0.877 * (r - y)
        let ku = 0.492 * (kb - ky)
        let kv = 0.877 * (kr - ky)
        let du = u - ku
        let dv = v - kv
        return sqrt(du * du + dv * dv)
    }

    private static func opaqueBounds(
        pixels: [UInt8],
        width: Int,
        height: Int,
        alphaThreshold: UInt8
    ) -> Bounds {
        var b = Bounds.empty
        for y in 0..<height {
            for x in 0..<width {
                let a = pixels[(y * width + x) * 4 + 3]
                if a > alphaThreshold {
                    if b.isEmpty {
                        b = Bounds(minX: x, minY: y, maxX: x, maxY: y)
                    } else {
                        b.minX = min(b.minX, x)
                        b.minY = min(b.minY, y)
                        b.maxX = max(b.maxX, x)
                        b.maxY = max(b.maxY, y)
                    }
                }
            }
        }
        return b
    }

    private static func parseHex(_ hex: String) -> (r: Double, g: Double, b: Double) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return (0, 0.756, 0.027)
        }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return (r, g, b)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ChromaKeyError.processFailed("无法创建 PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ChromaKeyError.processFailed("写入 PNG 失败")
        }
    }
}
