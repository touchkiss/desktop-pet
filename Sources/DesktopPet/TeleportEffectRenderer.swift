import AppKit
import CoreImage
import DesktopPetCore
import QuartzCore

final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Overlay windows must land EXACTLY where asked. AppKit's default
/// constrain logic pushes a window down so its top stays below the menu
/// bar — for our oversized effect canvases that silently shoved the staged
/// cat (and the whole effect) below the live pet: the "video dips down,
/// then the effect plays / then it jumps back up" bug.
final class UnconstrainedOverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Cinematic teleport FX tuned for a small transparent pet window.
/// Principle: distort the pet snapshot first; light / dust only supports it.
@MainActor
final class TeleportEffectRenderer {
    private weak var host: NSView?
    private let overlay = CALayer()
    private var completionWorkItem: DispatchWorkItem?
    private var bubbleDismissWorkItem: DispatchWorkItem?
    private var particleStopWorkItem: DispatchWorkItem?
    private var bubbleView: NSTextField?
    private var savedImage: NSImage?
    private var stagingLayer: CALayer?
    /// Dedicated transparent effect-canvas window, spawned per effect.
    /// Effects render HERE — generously larger than the pet window — so
    /// rings, dust and dashes never get clipped by the video's bounds.
    /// 特效是特效、视频是视频。
    private var canvasWindow: NSWindow?
    /// The pet's rect in canvas coordinates while an effect is running.
    private var stagedPetRect: CGRect = .zero
    /// Snapshot of the most recent effect — the middle bridge borrows it
    /// for the cloud rider and the hop silhouettes.
    private(set) var lastPetSnapshot: CGImage?
    /// Layers whose `contents` track the pet's CURRENT frame during an
    /// effect — the cat keeps moving while it dissolves / materializes,
    /// instead of freezing into a static sticker.
    private var liveContentLayers: [CALayer] = []

    var setEffectPadding: ((CGFloat) -> Void)?
    /// While true, the live view renders blank; the effect's staging layers
    /// display the (still flowing) frames instead.
    var setLiveImageSuppressed: ((Bool) -> Void)?

    /// Feed the freshest engine frame into every registered staging layer.
    func updateLiveFrame(_ image: NSImage) {
        guard !liveContentLayers.isEmpty else { return }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in liveContentLayers {
            layer.contents = cg
        }
        CATransaction.commit()
    }

    // Warm, photographic palette (avoid neon cyan / purple)
    private static let gold = NSColor(calibratedRed: 0.92, green: 0.68, blue: 0.28, alpha: 1)
    private static let goldSoft = NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.55, alpha: 1)
    private static let beamCore = NSColor(calibratedRed: 0.78, green: 0.92, blue: 1.0, alpha: 1)
    private static let beamHalo = NSColor(calibratedRed: 0.55, green: 0.78, blue: 0.95, alpha: 1)
    private static let ashWarm = NSColor(calibratedRed: 0.62, green: 0.55, blue: 0.48, alpha: 1)
    private static let ashCool = NSColor(calibratedRed: 0.48, green: 0.50, blue: 0.55, alpha: 1)
    private static let mistTint = NSColor(calibratedWhite: 0.92, alpha: 1)

    private static let softGlow: CGImage = makeRadial(size: 48, color: .white)
    private static let softDust: CGImage = makeRadial(size: 16, color: .white)
    private static let softSpark: CGImage = makeRadial(size: 10, color: .white)

    private static func makeRadial(size: Int, color: NSColor) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        rect.fill()
        NSGradient(colors: [
            color.withAlphaComponent(1),
            color.withAlphaComponent(0.35),
            color.withAlphaComponent(0)
        ])?.draw(in: rect, relativeCenterPosition: .zero)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private static let easeOutSoft = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
    private static let easeInSoft = CAMediaTimingFunction(controlPoints: 0.55, 0.06, 0.68, 0.19)
    private static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)

    init(host: NSView) {
        self.host = host
        host.wantsLayer = true
        overlay.name = "teleportOverlay"
        overlay.masksToBounds = false
        // NOTE: the overlay is parented into the effect-canvas window per
        // effect, never into the pet view — effects must not be clipped by
        // (or resize) the video window.
    }

    func cancel() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        bubbleDismissWorkItem?.cancel()
        bubbleDismissWorkItem = nil
        particleStopWorkItem?.cancel()
        particleStopWorkItem = nil
        teardownStaging()
        setEffectPadding?(0)
        if let host {
            host.layer?.removeAllAnimations()
            host.layer?.mask = nil
            host.alphaValue = 1
            host.layer?.opacity = 1
            host.layer?.transform = CATransform3DIdentity
            if let pet = host as? PetContentView, let savedImage {
                pet.image = savedImage
            }
        }
        savedImage = nil
        dismissBubble()
    }

    /// `direction` is the unit travel vector of the whole trip (origin →
    /// destination). Vanish dashes towards it, appear slides in from it;
    /// styles that don't move only mirror their particle drift to match.
    func playVanish(
        style: TeleportEffectStyle,
        onPet: NSView,
        towards direction: CGVector? = nil,
        completion: @escaping () -> Void
    ) {
        prepare(onPet: onPet)
        switch style {
        case .particles: thanosAsh(vanish: true, onPet: onPet, direction: direction, completion: completion)
        case .beam: lightBeam(vanish: true, onPet: onPet, completion: completion)
        case .blink: flashBlink(vanish: true, onPet: onPet, direction: direction, completion: completion)
        case .pixel: pixelate(vanish: true, onPet: onPet, completion: completion)
        case .smear: smear(vanish: true, onPet: onPet, direction: direction, completion: completion)
        case .scanline: scanline(vanish: true, onPet: onPet, completion: completion)
        case .ink: inkBloom(vanish: true, onPet: onPet, completion: completion)
        case .develop: develop(vanish: true, onPet: onPet, completion: completion)
        // Swarm is a whole-trip effect handled by TileSwarmRenderer; the
        // controller branches before reaching this pipeline. Defensive
        // fallback so the switch stays exhaustive.
        case .swarm: pixelate(vanish: true, onPet: onPet, completion: completion)
        }
    }

    func playAppear(
        style: TeleportEffectStyle,
        onPet: NSView,
        towards direction: CGVector? = nil,
        completion: @escaping () -> Void
    ) {
        prepare(onPet: onPet)
        switch style {
        case .particles: thanosAsh(vanish: false, onPet: onPet, direction: direction, completion: completion)
        case .beam: lightBeam(vanish: false, onPet: onPet, completion: completion)
        case .blink: flashBlink(vanish: false, onPet: onPet, direction: direction, completion: completion)
        case .pixel: pixelate(vanish: false, onPet: onPet, completion: completion)
        case .smear: smear(vanish: false, onPet: onPet, direction: direction, completion: completion)
        case .scanline: scanline(vanish: false, onPet: onPet, completion: completion)
        case .ink: inkBloom(vanish: false, onPet: onPet, completion: completion)
        case .develop: develop(vanish: false, onPet: onPet, completion: completion)
        // Same defensive fallback as playVanish — swarm never routes here.
        case .swarm: pixelate(vanish: false, onPet: onPet, completion: completion)
        }
    }

    // MARK: - Pixel crumble

    private func pixelate(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        // Mosaic breakdown: the cat crumbles into tiles that tumble away;
        // on appear the tiles fly back and snap together, bottom rows first.
        let duration: CFTimeInterval = 1.2
        beginEffect(onPet: onPet, padding: 110, fallback: completion) { [weak self] snap in
            self?.runPixelate(vanish: vanish, onPet: onPet, snapshot: snap, duration: duration, completion: completion)
        }
    }

    private func runPixelate(vanish: Bool, onPet: NSView, snapshot: CGImage, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        let grid = 12
        let cellW = rect.width / CGFloat(grid)
        let cellH = rect.height / CGFloat(grid)
        let t0 = CACurrentMediaTime()

        let container = CALayer()
        container.frame = overlay.bounds
        overlay.addSublayer(container)
        stagingLayer = container

        for row in 0..<grid {
            for col in 0..<grid {
                let tile = CALayer()
                tile.frame = CGRect(
                    x: rect.minX + CGFloat(col) * cellW,
                    y: rect.minY + CGFloat(row) * cellH,
                    width: ceil(cellW) + 0.5,
                    height: ceil(cellH) + 0.5
                )
                tile.contents = snapshot
                tile.contentsRect = CGRect(
                    x: CGFloat(col) / CGFloat(grid),
                    y: CGFloat(row) / CGFloat(grid),
                    width: 1 / CGFloat(grid),
                    height: 1 / CGFloat(grid)
                )
                tile.contentsGravity = .resize
                container.addSublayer(tile)
                liveContentLayers.append(tile)

                let home = tile.position
                let scattered = CGPoint(
                    x: home.x + CGFloat.random(in: -90...90),
                    y: home.y + (vanish
                        ? CGFloat.random(in: -170 ... -60)
                        : CGFloat.random(in: 60...180))
                )
                // Bottom rows lead: crumble loses support first, assembly
                // builds its foundation first.
                let delay = Double(row) / Double(max(1, grid - 1)) * 0.28
                    + Double.random(in: 0...0.14)
                let begin = t0 + delay
                let moveDuration = duration * 0.5
                let timing = vanish ? Self.easeInSoft : Self.easeOutSoft

                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = vanish ? home : scattered
                move.toValue = vanish ? scattered : home
                let tumble = CABasicAnimation(keyPath: "transform.rotation.z")
                let angle = CGFloat.random(in: -1.4...1.4)
                tumble.fromValue = vanish ? 0 : angle
                tumble.toValue = vanish ? angle : 0
                let sizing = CABasicAnimation(keyPath: "transform.scale")
                sizing.fromValue = vanish ? 1 : 0.55
                sizing.toValue = vanish ? 0.55 : 1
                let tileFade = CABasicAnimation(keyPath: "opacity")
                tileFade.fromValue = vanish ? 1 : 0
                tileFade.toValue = vanish ? 0 : 1

                for animation in [move, tumble, sizing, tileFade] {
                    animation.beginTime = begin
                    animation.duration = moveDuration
                    animation.timingFunction = timing
                    animation.fillMode = .both
                    animation.isRemovedOnCompletion = false
                }
                tile.add(move, forKey: "m")
                tile.add(tumble, forKey: "r")
                tile.add(sizing, forKey: "s")
                tile.add(tileFade, forKey: "f")

                tile.position = vanish ? scattered : home
                tile.opacity = vanish ? 0 : 1
                tile.transform = vanish
                    ? CATransform3DRotate(CATransform3DMakeScale(0.55, 0.55, 1), angle, 0, 0, 1)
                    : CATransform3DIdentity
            }
        }

        if !vanish {
            addLandingAmbience(rect: rect, duration: duration)
        }

        finish(after: duration, tail: 0.18, onPet: onPet, completion: completion)
    }

    // MARK: - Smear dash (拉丝瞬移)

    private func smear(vanish: Bool, onPet: NSView, direction: CGVector?, completion: @escaping () -> Void) {
        // The cat stretches into a motion-blurred streak of itself along
        // the travel direction and snaps away; arrival plays it backwards
        // with an overshoot. Move-style: bridges pair with it.
        let duration: CFTimeInterval = 0.55
        beginEffect(onPet: onPet, padding: 150, fallback: completion) { [weak self] snap in
            self?.runSmear(vanish: vanish, onPet: onPet, snapshot: snap, direction: direction, duration: duration, completion: completion)
        }
    }

    private func runSmear(
        vanish: Bool,
        onPet: NSView,
        snapshot: CGImage,
        direction: CGVector?,
        duration: CFTimeInterval,
        completion: @escaping () -> Void
    ) {
        let rect = petRect(in: onPet)
        let dir = direction ?? CGVector(dx: 1, dy: 0)
        let angle = CGFloat(atan2(Double(dir.dy), Double(dir.dx)))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let t0 = CACurrentMediaTime()

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snapshot
        petLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        petLayer.position = center
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer
        liveContentLayers.append(petLayer)

        // True motion blur along the travel direction.
        if let motion = CIFilter(name: "CIMotionBlur") {
            motion.setValue(0, forKey: kCIInputRadiusKey)
            motion.setValue(angle, forKey: kCIInputAngleKey)
            motion.name = "smearBlur"
            petLayer.filters = [motion]
            let blurAnim = CABasicAnimation(keyPath: "filters.smearBlur.inputRadius")
            blurAnim.fromValue = vanish ? 0 : 24
            blurAnim.toValue = vanish ? 24 : 0
            blurAnim.beginTime = t0 + (vanish ? duration * 0.18 : 0)
            blurAnim.duration = duration * (vanish ? 0.5 : 0.6)
            blurAnim.timingFunction = vanish ? Self.easeInSoft : Self.easeOutSoft
            blurAnim.fillMode = .both
            blurAnim.isRemovedOnCompletion = false
            petLayer.add(blurAnim, forKey: "mb")
        }

        // Anisotropic stretch along an arbitrary direction:
        // translate → rotate → scale → un-rotate, pivoted at the center.
        func stretch(_ along: CGFloat, _ across: CGFloat, drift: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(dir.dx * drift, dir.dy * drift, 0)
            t = CATransform3DRotate(t, angle, 0, 0, 1)
            t = CATransform3DScale(t, along, across, 1)
            t = CATransform3DRotate(t, -angle, 0, 0, 1)
            return t
        }
        let smearOut = stretch(2.6, 0.55, drift: rect.width * 0.9)
        let recoil = stretch(0.92, 1.06, drift: -rect.width * 0.06)
        let smearIn = stretch(2.6, 0.55, drift: -rect.width * 0.9)
        let overshoot = stretch(0.94, 1.05, drift: rect.width * 0.03)

        let morph = CAKeyframeAnimation(keyPath: "transform")
        if vanish {
            morph.values = [
                NSValue(caTransform3D: CATransform3DIdentity),
                NSValue(caTransform3D: recoil),
                NSValue(caTransform3D: smearOut)
            ]
            morph.keyTimes = [0, 0.3, 1]
            morph.timingFunctions = [Self.easeOutSoft, Self.easeInSoft]
        } else {
            morph.values = [
                NSValue(caTransform3D: smearIn),
                NSValue(caTransform3D: overshoot),
                NSValue(caTransform3D: CATransform3DIdentity)
            ]
            morph.keyTimes = [0, 0.7, 1]
            morph.timingFunctions = [Self.easeOutSoft, Self.easeInOut]
        }
        morph.beginTime = t0
        morph.duration = duration
        morph.fillMode = .both
        morph.isRemovedOnCompletion = false
        petLayer.add(morph, forKey: "t")
        petLayer.transform = vanish ? smearOut : CATransform3DIdentity

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = vanish ? [1, 1, 0] : [0, 1, 1]
        fade.keyTimes = vanish ? [0, 0.6, 0.95] : [0, 0.3, 1]
        fade.beginTime = t0
        fade.duration = duration
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        petLayer.add(fade, forKey: "o")
        petLayer.opacity = vanish ? 0 : 1

        // Two speed lines shadowing the dash.
        let perp = CGVector(dx: -dir.dy, dy: dir.dx)
        for (offset, delay) in [(rect.height * 0.18, 0.0), (-rect.height * 0.14, 0.04)] {
            let base = CGPoint(x: center.x + perp.dx * offset, y: center.y + perp.dy * offset)
            let span = rect.width * 1.2
            let linePath = CGMutablePath()
            if vanish {
                linePath.move(to: CGPoint(x: base.x - dir.dx * span * 0.3, y: base.y - dir.dy * span * 0.3))
                linePath.addLine(to: CGPoint(x: base.x + dir.dx * span, y: base.y + dir.dy * span))
            } else {
                linePath.move(to: CGPoint(x: base.x - dir.dx * span, y: base.y - dir.dy * span))
                linePath.addLine(to: CGPoint(x: base.x + dir.dx * span * 0.3, y: base.y + dir.dy * span * 0.3))
            }
            let line = CAShapeLayer()
            line.path = linePath
            line.strokeColor = Self.beamCore.withAlphaComponent(0.7).cgColor
            line.fillColor = nil
            line.lineWidth = 1.4
            line.lineCap = .round
            line.strokeEnd = 0
            overlay.addSublayer(line)

            let begin = t0 + (vanish ? duration * 0.3 : 0) + delay
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.beginTime = begin
            draw.duration = 0.12
            draw.timingFunction = Self.easeOutSoft
            draw.fillMode = .both
            draw.isRemovedOnCompletion = false
            line.add(draw, forKey: "draw")
            line.strokeEnd = 1

            let chase = CABasicAnimation(keyPath: "strokeStart")
            chase.fromValue = 0
            chase.toValue = 1
            chase.beginTime = begin + 0.07
            chase.duration = 0.13
            chase.timingFunction = Self.easeInSoft
            chase.fillMode = .both
            chase.isRemovedOnCompletion = false
            line.add(chase, forKey: "chase")
            line.strokeStart = 1
        }

        if !vanish {
            addLandingAmbience(rect: rect, duration: duration)
        }

        finish(after: duration, tail: 0.15, onPet: onPet, completion: completion)
    }

    // MARK: - Scanline rebuild (扫描线重组)

    /// Vertical variant of the noise band mask:
    /// `[clear H][noise band B][opaque H]` stacked top-to-bottom
    /// (mirrored when `opaqueOnTop` is false).
    private static func makeVerticalNoiseBandMask(
        petSize: CGSize,
        band: CGFloat,
        opaqueOnTop: Bool
    ) -> CGImage? {
        let scale: CGFloat = 0.5
        let petH = max(8, Int(petSize.height * scale))
        let bandH = max(6, Int(band * scale))
        let height = petH * 2 + bandH
        let width = max(8, Int(petSize.width * scale))

        let gw = 12
        let gh = 12
        var lattice = [Double](repeating: 0, count: (gw + 1) * (gh + 1))
        for i in lattice.indices { lattice[i] = Double.random(in: 0...1) }
        func noise(_ u: Double, _ v: Double) -> Double {
            let fx = min(0.999, max(0, u)) * Double(gw)
            let fy = min(0.999, max(0, v)) * Double(gh)
            let x0 = Int(fx)
            let y0 = Int(fy)
            let tx = fx - Double(x0)
            let ty = fy - Double(y0)
            let row = gw + 1
            let a = lattice[y0 * row + x0]
            let b = lattice[y0 * row + x0 + 1]
            let c = lattice[(y0 + 1) * row + x0]
            let d = lattice[(y0 + 1) * row + x0 + 1]
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let yi = opaqueOnTop ? y : (height - 1 - y)
            for x in 0..<width {
                let u = Double(x) / Double(max(1, width - 1))
                let alpha: Double
                if yi < petH {
                    alpha = 1
                } else if yi < petH + bandH {
                    let t = Double(yi - petH) / Double(bandH)
                    let n = noise(u, t)
                    alpha = min(1, max(0, ((1 - t) * 1.2 - n) * 5))
                } else {
                    alpha = 0
                }
                let p = (y * width + x) * 4
                let a8 = UInt8(alpha * 255)
                bytes[p] = a8
                bytes[p + 1] = a8
                bytes[p + 2] = a8
                bytes[p + 3] = a8
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    private func scanline(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        // A bright line sweeps top-to-bottom: erasing the cat on vanish,
        // printing it line by line on appear — scanner / SSTV feel.
        let duration: CFTimeInterval = 1.1
        beginEffect(onPet: onPet, padding: 70, fallback: completion) { [weak self] snap in
            self?.runScanline(vanish: vanish, onPet: onPet, snapshot: snap, duration: duration, completion: completion)
        }
    }

    private func runScanline(vanish: Bool, onPet: NSView, snapshot: CGImage, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        let t0 = CACurrentMediaTime()

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snapshot
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer
        liveContentLayers.append(petLayer)

        // Sweeping noise-edged mask. Vanish: the opaque zone (below the
        // band) shrinks downward as the band sweeps down. Appear: the band
        // sweeps down printing opaque above itself.
        let bandHeight = max(20, rect.height * 0.3)
        let maskHeight = rect.height * 2 + bandHeight
        let mask = CALayer()
        mask.contentsGravity = .resize
        mask.contents = Self.makeVerticalNoiseBandMask(
            petSize: rect.size,
            band: bandHeight,
            opaqueOnTop: !vanish
        )
        // Image layout (opaqueOnTop=true): [opaque H][band][clear H] from top.
        // BOTH directions slide the mask down by pet height + band, so the
        // boundary tracks the bright head top→bottom; the image choice above
        // decides whether that boundary erases (vanish: opaque below the
        // band) or prints (appear: opaque above it).
        let startOriginY: CGFloat = 0
        let endOriginY: CGFloat = -(rect.height + bandHeight)
        mask.frame = CGRect(x: -2, y: startOriginY, width: rect.width + 4, height: maskHeight)
        petLayer.mask = mask

        let startPosY = startOriginY + maskHeight / 2
        let endPosY = endOriginY + maskHeight / 2
        let sweep = CABasicAnimation(keyPath: "position.y")
        sweep.fromValue = startPosY
        sweep.toValue = endPosY
        sweep.duration = duration * 0.85
        sweep.beginTime = t0 + duration * 0.08
        sweep.timingFunction = Self.easeInOut
        sweep.fillMode = .both
        sweep.isRemovedOnCompletion = false
        mask.add(sweep, forKey: "sweep")
        // NB: mask coordinates live in petLayer's BOUNDS space — rect.midX
        // (canvas space) would shove the mask sideways off the pet entirely,
        // leaving the snapshot fully masked-out for the whole sweep.
        mask.position = CGPoint(x: rect.width / 2, y: endPosY)

        // The bright printing head travels with the boundary.
        let head = CAGradientLayer()
        head.bounds = CGRect(x: 0, y: 0, width: rect.width * 1.25, height: 3.5)
        head.startPoint = CGPoint(x: 0, y: 0.5)
        head.endPoint = CGPoint(x: 1, y: 0.5)
        head.colors = [
            Self.beamCore.withAlphaComponent(0).cgColor,
            Self.beamCore.withAlphaComponent(0.9).cgColor,
            NSColor.white.withAlphaComponent(0.95).cgColor,
            Self.beamCore.withAlphaComponent(0.9).cgColor,
            Self.beamCore.withAlphaComponent(0).cgColor
        ]
        head.locations = [0, 0.25, 0.5, 0.75, 1]
        head.shadowColor = Self.beamCore.cgColor
        head.shadowRadius = 6
        head.shadowOpacity = 0.9
        head.shadowOffset = .zero
        head.opacity = 0
        overlay.addSublayer(head)

        // Chromatic fringes hugging the head.
        let fringeColors: [(NSColor, CGFloat)] = [
            (NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.35, alpha: 1), 3.0),
            (NSColor(calibratedRed: 0.35, green: 0.9, blue: 1.0, alpha: 1), -3.0)
        ]
        var fringes: [CALayer] = []
        for (color, offset) in fringeColors {
            let fringe = CALayer()
            fringe.bounds = CGRect(x: 0, y: 0, width: rect.width * 1.1, height: 1.5)
            fringe.backgroundColor = color.withAlphaComponent(0.35).cgColor
            fringe.opacity = 0
            fringe.setValue(offset, forKey: "fringeOffset")
            overlay.addSublayer(fringe)
            fringes.append(fringe)
        }

        let sweepFromY = rect.maxY
        let sweepToY = rect.minY
        // The boundary always travels top→bottom of the pet: start at maxY.
        let headMove = CABasicAnimation(keyPath: "position.y")
        headMove.fromValue = sweepFromY
        headMove.toValue = sweepToY
        headMove.duration = duration * 0.85
        headMove.beginTime = t0 + duration * 0.08
        headMove.timingFunction = Self.easeInOut
        headMove.fillMode = .both
        headMove.isRemovedOnCompletion = false
        head.position = CGPoint(x: rect.midX, y: sweepToY)
        head.add(headMove, forKey: "move")

        let headOp = CAKeyframeAnimation(keyPath: "opacity")
        headOp.values = [0, 1, 0.85, 1, 0.9, 0]
        headOp.keyTimes = [0, 0.12, 0.4, 0.6, 0.88, 1]
        headOp.beginTime = t0
        headOp.duration = duration
        headOp.fillMode = .both
        headOp.isRemovedOnCompletion = false
        head.add(headOp, forKey: "o")

        for fringe in fringes {
            let offset = (fringe.value(forKey: "fringeOffset") as? CGFloat) ?? 0
            let fringeMove = CABasicAnimation(keyPath: "position.y")
            fringeMove.fromValue = sweepFromY + offset
            fringeMove.toValue = sweepToY + offset
            fringeMove.duration = duration * 0.85
            fringeMove.beginTime = t0 + duration * 0.08
            fringeMove.timingFunction = Self.easeInOut
            fringeMove.fillMode = .both
            fringeMove.isRemovedOnCompletion = false
            fringe.position = CGPoint(x: rect.midX, y: sweepToY + offset)
            fringe.add(fringeMove, forKey: "move")

            let fringeOp = CAKeyframeAnimation(keyPath: "opacity")
            fringeOp.values = [0, 0.8, 0.6, 0.8, 0]
            fringeOp.keyTimes = [0, 0.15, 0.5, 0.85, 1]
            fringeOp.beginTime = t0
            fringeOp.duration = duration
            fringeOp.fillMode = .both
            fringeOp.isRemovedOnCompletion = false
            fringe.add(fringeOp, forKey: "o")
        }

        if !vanish {
            addLandingAmbience(rect: rect, duration: duration)
        }

        finish(after: duration, tail: 0.18, onPet: onPet, completion: completion)
    }

    // MARK: - Ink bloom (墨滴晕染)

    private func inkBloom(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        // 水墨：消失时去色、虚化、如墨入水从毛边处晕开散去；
        // 出现时一滴墨自中心洇开，边缘碎块生长，随后聚色凝形。
        let duration: CFTimeInterval = 1.25
        beginEffect(onPet: onPet, padding: 80, fallback: completion) { [weak self] snap in
            self?.runInkBloom(vanish: vanish, onPet: onPet, snapshot: snap, duration: duration, completion: completion)
        }
    }

    private func runInkBloom(vanish: Bool, onPet: NSView, snapshot: CGImage, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        let t0 = CACurrentMediaTime()

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snapshot
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer
        liveContentLayers.append(petLayer)

        // Crumble-edged blot mask (the noise disc from the old portal iris).
        let blotDiameter = max(rect.width, rect.height) * 1.6
        let blot = CALayer()
        blot.bounds = CGRect(x: 0, y: 0, width: blotDiameter, height: blotDiameter)
        blot.position = CGPoint(x: petLayer.bounds.midX, y: petLayer.bounds.midY)
        blot.contents = Self.makeNoiseDiscMask(
            diameter: blotDiameter,
            band: blotDiameter * 0.22
        )
        petLayer.mask = blot

        let blotScale = CABasicAnimation(keyPath: "transform.scale")
        blotScale.fromValue = vanish ? 1.05 : 0.03
        blotScale.toValue = vanish ? 0.03 : 1.05
        blotScale.beginTime = t0 + (vanish ? duration * 0.3 : duration * 0.05)
        blotScale.duration = duration * (vanish ? 0.62 : 0.7)
        blotScale.timingFunction = vanish ? Self.easeInSoft : Self.easeOutSoft
        blotScale.fillMode = .both
        blotScale.isRemovedOnCompletion = false
        blot.add(blotScale, forKey: "blot")
        blot.transform = CATransform3DMakeScale(vanish ? 0.03 : 1.05, vanish ? 0.03 : 1.05, 1)

        // Desaturate + soften: colour drains as the ink takes over.
        var petFilters: [CIFilter] = []
        if let colorControl = CIFilter(name: "CIColorControls") {
            colorControl.setValue(vanish ? 1.0 : 0.0, forKey: kCIInputSaturationKey)
            colorControl.name = "inkColor"
            petFilters.append(colorControl)
        }
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(0, forKey: kCIInputRadiusKey)
            blur.name = "inkBlur"
            petFilters.append(blur)
        }
        if !petFilters.isEmpty {
            petLayer.filters = petFilters

            let desat = CABasicAnimation(keyPath: "filters.inkColor.inputSaturation")
            desat.fromValue = vanish ? 1.0 : 0.0
            desat.toValue = vanish ? 0.0 : 1.0
            desat.beginTime = t0 + (vanish ? 0 : duration * 0.35)
            desat.duration = duration * 0.55
            desat.timingFunction = Self.easeInOut
            desat.fillMode = .both
            desat.isRemovedOnCompletion = false
            petLayer.add(desat, forKey: "desat")

            let soften = CABasicAnimation(keyPath: "filters.inkBlur.inputRadius")
            soften.fromValue = vanish ? 0 : 5
            soften.toValue = vanish ? 5 : 0
            soften.beginTime = t0 + (vanish ? duration * 0.15 : duration * 0.3)
            soften.duration = duration * 0.55
            soften.timingFunction = Self.easeInOut
            soften.fillMode = .both
            soften.isRemovedOnCompletion = false
            petLayer.add(soften, forKey: "soften")
        }

        // Ink silhouette: the cat darkens toward pure ink mid-transition.
        let inkShell = CALayer()
        inkShell.frame = rect
        inkShell.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        let inkMask = CALayer()
        inkMask.frame = CGRect(origin: .zero, size: rect.size)
        inkMask.contents = snapshot
        inkShell.mask = inkMask
        inkShell.opacity = 0
        overlay.addSublayer(inkShell)
        liveContentLayers.append(inkMask)

        let inkTint = CAKeyframeAnimation(keyPath: "opacity")
        inkTint.values = vanish ? [0, 0.35, 0.55, 0] : [0.55, 0.4, 0.15, 0]
        inkTint.keyTimes = vanish ? [0, 0.3, 0.6, 0.95] : [0, 0.35, 0.7, 1]
        inkTint.beginTime = t0
        inkTint.duration = duration
        inkTint.fillMode = .both
        inkTint.isRemovedOnCompletion = false
        inkShell.add(inkTint, forKey: "o")

        if !vanish {
            addLandingAmbience(rect: rect, duration: duration)
        }

        finish(after: duration, tail: 0.2, onPet: onPet, completion: completion)
    }

    // MARK: - Photo develop (老照片显影)

    private func develop(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        // Polaroid: appear develops the image out of a blank white frame
        // (sepia → colour, contrast ramps up); vanish washes it back out.
        let duration: CFTimeInterval = 1.3
        beginEffect(onPet: onPet, padding: 60, fallback: completion) { [weak self] snap in
            self?.runDevelop(vanish: vanish, onPet: onPet, snapshot: snap, duration: duration, completion: completion)
        }
    }

    private func runDevelop(vanish: Bool, onPet: NSView, snapshot: CGImage, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        let t0 = CACurrentMediaTime()

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snapshot
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer
        liveContentLayers.append(petLayer)

        var petFilters: [CIFilter] = []
        if let sepia = CIFilter(name: "CISepiaTone") {
            sepia.setValue(vanish ? 0.0 : 0.9, forKey: kCIInputIntensityKey)
            sepia.name = "devSepia"
            petFilters.append(sepia)
        }
        if let colorControl = CIFilter(name: "CIColorControls") {
            colorControl.setValue(vanish ? 1.0 : 0.25, forKey: kCIInputSaturationKey)
            colorControl.name = "devColor"
            petFilters.append(colorControl)
        }
        if !petFilters.isEmpty {
            petLayer.filters = petFilters

            let sepiaAnim = CABasicAnimation(keyPath: "filters.devSepia.inputIntensity")
            sepiaAnim.fromValue = vanish ? 0.0 : 0.9
            sepiaAnim.toValue = vanish ? 0.9 : 0.0
            sepiaAnim.beginTime = t0 + duration * 0.1
            sepiaAnim.duration = duration * 0.6
            sepiaAnim.timingFunction = Self.easeInOut
            sepiaAnim.fillMode = .both
            sepiaAnim.isRemovedOnCompletion = false
            petLayer.add(sepiaAnim, forKey: "sepia")

            let satAnim = CABasicAnimation(keyPath: "filters.devColor.inputSaturation")
            satAnim.fromValue = vanish ? 1.0 : 0.25
            satAnim.toValue = vanish ? 0.25 : 1.0
            satAnim.beginTime = t0 + duration * 0.15
            satAnim.duration = duration * 0.6
            satAnim.timingFunction = Self.easeInOut
            satAnim.fillMode = .both
            satAnim.isRemovedOnCompletion = false
            petLayer.add(satAnim, forKey: "sat")
        }

        // The white wash: development happens under it (appear), or it
        // floods back over the picture (vanish). Uneven keyframes give it
        // the chemical, non-linear feel of a real print.
        let wash = addEnergyShell(rect: rect, snapshot: snapshot)
        let washAnim = CAKeyframeAnimation(keyPath: "opacity")
        if vanish {
            washAnim.values = [0, 0.2, 0.5, 0.75, 0.95, 0]
            washAnim.keyTimes = [0, 0.25, 0.45, 0.62, 0.82, 1]
        } else {
            washAnim.values = [0.95, 0.85, 0.6, 0.35, 0.12, 0]
            washAnim.keyTimes = [0, 0.2, 0.42, 0.62, 0.82, 1]
        }
        washAnim.beginTime = t0
        washAnim.duration = duration
        washAnim.fillMode = .both
        washAnim.isRemovedOnCompletion = false
        wash.add(washAnim, forKey: "wash")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = vanish ? 1 : 0
        fade.toValue = vanish ? 0 : 1
        fade.beginTime = t0 + (vanish ? duration * 0.72 : 0)
        fade.duration = duration * (vanish ? 0.25 : 0.3)
        fade.timingFunction = vanish ? Self.easeInSoft : Self.easeOutSoft
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        petLayer.add(fade, forKey: "o")
        petLayer.opacity = vanish ? 0 : 1

        if !vanish {
            addLandingAmbience(rect: rect, duration: duration)
        }

        finish(after: duration, tail: 0.18, onPet: onPet, completion: completion)
    }


    // MARK: - Reminder bubble

    func showReminderBubble(text: String, near petView: NSView, duration: TimeInterval = 3.5) {
        dismissBubble()
        guard let petView = host ?? petView as NSView? else { return }
        let label = PassthroughTextField(labelWithString: text)
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        label.layer?.cornerRadius = 8
        label.textColor = .white
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.drawsBackground = false
        label.sizeToFit()
        var frame = label.frame
        frame.size.width += 16
        frame.size.height += 10
        let petRect = (petView as? PetContentView)?.imageDrawRect ?? petView.bounds
        frame.origin.x = petRect.midX - frame.width / 2
        frame.origin.y = petRect.maxY + 6
        if let win = petView.window, let screen = win.screen, win.frame.midY > screen.visibleFrame.midY {
            frame.origin.y = petRect.minY - frame.height - 6
        }
        label.frame = frame
        label.alphaValue = 0
        petView.addSubview(label)
        bubbleView = label
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            label.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.dismissBubble() }
        bubbleDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismissBubble() {
        bubbleDismissWorkItem?.cancel()
        bubbleDismissWorkItem = nil
        bubbleView?.removeFromSuperview()
        bubbleView = nil
    }

    // MARK: - Prep / teardown

    private func prepare(onPet: NSView) {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        particleStopWorkItem?.cancel()
        particleStopWorkItem = nil
        teardownStaging()
        onPet.layer?.removeAllAnimations()
        onPet.layer?.mask = nil
        onPet.wantsLayer = true
    }

    private func teardownStaging() {
        stagingLayer?.removeFromSuperlayer()
        stagingLayer = nil
        liveContentLayers.removeAll()
        setLiveImageSuppressed?(false)
        clearOverlay()
        overlay.removeFromSuperlayer()
        closeCanvas()
    }

    private func makeCanvasWindow(frame: CGRect, level: NSWindow.Level) -> NSWindow {
        let win = UnconstrainedOverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = level
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        let hostView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        hostView.wantsLayer = true
        win.contentView = hostView
        win.orderFrontRegardless()
        return win
    }

    private func closeCanvas() {
        canvasWindow?.orderOut(nil)
        canvasWindow = nil
    }

    private func clearOverlay() {
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        overlay.removeAllAnimations()
    }

    /// `tail` keeps the overlay alive after the main action so lingering
    /// particles fade out on their own instead of being hard-cut mid-air.
    private func finish(
        after duration: CFTimeInterval,
        tail: CFTimeInterval,
        onPet: NSView,
        completion: @escaping () -> Void
    ) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Restore the live pet FIRST, close the canvas a tick later —
            // the two overlap for one frame instead of leaving a gap.
            self.setLiveImageSuppressed?(false)
            self.setEffectPadding?(0)
            onPet.layer?.mask = nil
            onPet.alphaValue = 1
            onPet.layer?.opacity = 1
            onPet.layer?.transform = CATransform3DIdentity
            if let pet = onPet as? PetContentView, let saved = self.savedImage {
                pet.image = saved
            }
            self.savedImage = nil
            let canvasAtFinish = self.canvasWindow
            DispatchQueue.main.async { [weak self] in
                guard let self, self.canvasWindow === canvasAtFinish else { return }
                self.teardownStaging()
            }
            completion()
        }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + tail, execute: work)
    }

    private func snapshot(_ view: NSView) -> (NSImage, CGImage)? {
        if let pet = view as? PetContentView, let image = pet.renderedSnapshot() {
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            return (image, cg)
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { return nil }
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return (image, cg)
    }

    private func petRect(in view: NSView) -> CGRect {
        if canvasWindow != nil { return stagedPetRect }
        return (view as? PetContentView)?.imageDrawRect ?? view.bounds
    }

    private func hideLivePet(_ view: NSView) {
        if let pet = view as? PetContentView {
            savedImage = pet.image
            pet.image = nil
        } else {
            view.alphaValue = 0
        }
    }

    /// Bootstrap shared by every effect.
    ///
    /// Spawns the effect-canvas window around the pet (generously larger
    /// than the video, scaled by pet size plus the effect's own margin
    /// hint), stages everything there, and swaps live pet → staged frames
    /// inside one transaction so the hand-off never flashes. The video
    /// window itself is never resized or drawn into.
    private func beginEffect(
        onPet: NSView,
        padding: CGFloat,
        fallback: @escaping () -> Void,
        body: @escaping (CGImage) -> Void
    ) {
        guard let snap = snapshot(onPet), let petWindow = onPet.window else {
            finish(after: 0.05, tail: 0, onPet: onPet, completion: fallback)
            return
        }
        let petFrame = petWindow.frame
        let margin = max(220, max(petFrame.width, petFrame.height) * 0.9) + padding
        let canvasFrame = petFrame.insetBy(dx: -margin, dy: -margin)
        let canvas = makeCanvasWindow(frame: canvasFrame, level: petWindow.level)
        canvasWindow = canvas
        guard let root = canvas.contentView?.layer else {
            closeCanvas()
            finish(after: 0.05, tail: 0, onPet: onPet, completion: fallback)
            return
        }
        stagedPetRect = CGRect(
            x: petFrame.minX - canvasFrame.minX,
            y: petFrame.minY - canvasFrame.minY,
            width: petFrame.width,
            height: petFrame.height
        )
        overlay.frame = CGRect(origin: .zero, size: canvasFrame.size)
        root.addSublayer(overlay)
        lastPetSnapshot = snap.1
        hideLivePet(onPet)
        setLiveImageSuppressed?(true)
        onPet.alphaValue = 1
        body(snap.1)
    }

    /// Landing ambience for every appear: a flat dust ring rippling out at
    /// the feet plus a tiny canvas shake — weight, for free. Dust adapts
    /// to light/dark desktops.
    private func addLandingAmbience(rect: CGRect, duration: CFTimeInterval) {
        let begin = CACurrentMediaTime() + duration * 0.78
        let isDark = host?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let dustAlpha: CGFloat = isDark ? 0.6 : 0.45

        let ring = CAShapeLayer()
        let ringW = rect.width * 1.1
        let ringH = ringW * 0.26
        ring.bounds = CGRect(x: 0, y: 0, width: ringW, height: ringH)
        ring.position = CGPoint(x: rect.midX, y: rect.minY + ringH * 0.3)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = Self.ashWarm.withAlphaComponent(dustAlpha).cgColor
        ring.lineWidth = 2.2
        ring.opacity = 0
        overlay.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.25
        grow.toValue = 1.15
        grow.beginTime = begin
        grow.duration = 0.34
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        grow.fillMode = .both
        grow.isRemovedOnCompletion = false
        ring.add(grow, forKey: "grow")

        let thin = CABasicAnimation(keyPath: "lineWidth")
        thin.fromValue = 2.2
        thin.toValue = 0.4
        thin.beginTime = begin
        thin.duration = 0.34
        thin.fillMode = .both
        thin.isRemovedOnCompletion = false
        ring.add(thin, forKey: "thin")

        let ringOp = CAKeyframeAnimation(keyPath: "opacity")
        ringOp.values = [0, 0.9, 0]
        ringOp.keyTimes = [0, 0.25, 1]
        ringOp.beginTime = begin
        ringOp.duration = 0.34
        ringOp.fillMode = .both
        ringOp.isRemovedOnCompletion = false
        ring.add(ringOp, forKey: "o")

        let shake = CAKeyframeAnimation(keyPath: "transform.translation.y")
        shake.values = [0, -2.5, 1.8, -0.8, 0]
        shake.keyTimes = [0, 0.25, 0.55, 0.8, 1]
        shake.beginTime = begin
        shake.duration = 0.22
        shake.fillMode = .both
        shake.isRemovedOnCompletion = false
        overlay.add(shake, forKey: "landShake")
    }

    /// White "energy shell": the cat's own alpha filled with light, staged
    /// in the overlay. Vanish flashes it as the energize tell; appear keeps
    /// it up so the cat arrives AS light and anneals into the real thing.
    private func addEnergyShell(rect: CGRect, snapshot: CGImage) -> CALayer {
        let shell = CALayer()
        shell.frame = rect
        shell.backgroundColor = NSColor.white.cgColor
        let shellMask = CALayer()
        shellMask.frame = CGRect(origin: .zero, size: rect.size)
        shellMask.contents = snapshot
        shell.mask = shellMask
        shell.opacity = 0
        overlay.addSublayer(shell)
        liveContentLayers.append(shellMask)
        return shell
    }

    private func flashShell(_ shell: CALayer, vanish: Bool, duration: CFTimeInterval) {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        if vanish {
            // Energize flash up front, then a faint "residual heat" whiff
            // near the end before the last of the light dissipates.
            anim.values = [0, 0.55, 0, 0, 0.22, 0]
            anim.keyTimes = [0, 0.14, 0.3, 0.7, 0.84, 1]
            anim.duration = duration
        } else {
            anim.values = [0.85, 0.72, 0]
            anim.keyTimes = [0, 0.55, 1]
            anim.duration = duration * 0.85
        }
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        shell.add(anim, forKey: "energy")
    }

    /// "Energy gathering" cue: motes drift inward onto the landing spot
    /// during the first beat of an appear, so the cat doesn't form cold.
    private func addConvergenceCue(rect: CGRect, color: NSColor, duration: CFTimeInterval) {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: rect.midX, y: rect.midY)
        emitter.emitterShape = .circle
        emitter.emitterMode = .outline
        emitter.emitterSize = CGSize(width: rect.width * 1.7, height: rect.height * 1.7)
        emitter.renderMode = .additive
        emitter.birthRate = 0
        let mote = CAEmitterCell()
        mote.contents = Self.softSpark
        mote.birthRate = 130
        mote.lifetime = 0.4
        mote.lifetimeRange = 0.12
        mote.velocity = -70
        mote.velocityRange = 25
        mote.scale = 0.16
        mote.scaleRange = 0.08
        mote.alphaSpeed = -2.2
        mote.color = color.cgColor
        emitter.emitterCells = [mote]
        overlay.addSublayer(emitter)

        let gate = CAKeyframeAnimation(keyPath: "birthRate")
        gate.values = [1, 0]
        gate.keyTimes = [0, 0.3]
        gate.calculationMode = .discrete
        gate.duration = duration
        gate.fillMode = .both
        gate.isRemovedOnCompletion = false
        emitter.add(gate, forKey: "gate")
    }

    /// Animatable gaussian blur (macOS CALayer supports CoreImage filters).
    /// Returns false when the filter can't be created — callers just skip.
    private static func attachBlur(to layer: CALayer) -> Bool {
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return false }
        blur.setValue(0, forKey: kCIInputRadiusKey)
        blur.name = "petBlur"
        layer.filters = [blur]
        return true
    }

    private static func animateBlur(
        on layer: CALayer,
        from: CGFloat,
        to: CGFloat,
        begin: CFTimeInterval,
        duration: CFTimeInterval
    ) {
        let anim = CABasicAnimation(keyPath: "filters.petBlur.inputRadius")
        anim.fromValue = from
        anim.toValue = to
        anim.beginTime = begin
        anim.duration = duration
        anim.timingFunction = easeInOut
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "blur")
    }

    // MARK: - Ash dissolve

    /// Build the sliding dissolve mask: `[clear W][noise band B][opaque W]`
    /// (mirrored when `opaqueOnRight` is false). Inside the band each pixel
    /// flips from clear to opaque at a threshold offset by value noise, so
    /// the dissolve edge crumbles in pixel clusters instead of fading as a
    /// smooth gradient. Generated once per effect at half resolution.
    private static func makeNoiseBandMask(
        petSize: CGSize,
        band: CGFloat,
        opaqueOnRight: Bool
    ) -> CGImage? {
        let scale: CGFloat = 0.5
        let petW = max(8, Int(petSize.width * scale))
        let bandW = max(6, Int(band * scale))
        let width = petW * 2 + bandW
        let height = max(8, Int(petSize.height * scale))

        // Value noise: random lattice + bilinear interpolation → soft blobs.
        let gw = 12
        let gh = 12
        var lattice = [Double](repeating: 0, count: (gw + 1) * (gh + 1))
        for i in lattice.indices { lattice[i] = Double.random(in: 0...1) }
        func noise(_ u: Double, _ v: Double) -> Double {
            let fx = min(0.999, max(0, u)) * Double(gw)
            let fy = min(0.999, max(0, v)) * Double(gh)
            let x0 = Int(fx)
            let y0 = Int(fy)
            let tx = fx - Double(x0)
            let ty = fy - Double(y0)
            let row = gw + 1
            let a = lattice[y0 * row + x0]
            let b = lattice[y0 * row + x0 + 1]
            let c = lattice[(y0 + 1) * row + x0]
            let d = lattice[(y0 + 1) * row + x0 + 1]
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let v = Double(y) / Double(max(1, height - 1))
            for x in 0..<width {
                let xi = opaqueOnRight ? x : (width - 1 - x)
                let alpha: Double
                if xi < petW {
                    alpha = 0
                } else if xi < petW + bandW {
                    let t = Double(xi - petW) / Double(bandW)
                    let n = noise(t, v)
                    alpha = min(1, max(0, (t * 1.2 - n) * 5))
                } else {
                    alpha = 1
                }
                let p = (y * width + x) * 4
                let a8 = UInt8(alpha * 255)
                bytes[p] = a8
                bytes[p + 1] = a8
                bytes[p + 2] = a8
                bytes[p + 3] = a8
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Radial variant of the noise mask: a solid disc whose edge crumbles
    /// in pixel clusters. Scaling it animates a chunky-edged iris.
    private static func makeNoiseDiscMask(diameter: CGFloat, band: CGFloat) -> CGImage? {
        let scale: CGFloat = 0.5
        let size = max(24, Int(diameter * scale))
        let bandPx = max(3.0, Double(band * scale))
        let gw = 14
        let gh = 14
        var lattice = [Double](repeating: 0, count: (gw + 1) * (gh + 1))
        for i in lattice.indices { lattice[i] = Double.random(in: 0...1) }
        func noise(_ u: Double, _ v: Double) -> Double {
            let fx = min(0.999, max(0, u)) * Double(gw)
            let fy = min(0.999, max(0, v)) * Double(gh)
            let x0 = Int(fx)
            let y0 = Int(fy)
            let tx = fx - Double(x0)
            let ty = fy - Double(y0)
            let row = gw + 1
            let a = lattice[y0 * row + x0]
            let b = lattice[y0 * row + x0 + 1]
            let c = lattice[(y0 + 1) * row + x0]
            let d = lattice[(y0 + 1) * row + x0 + 1]
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
        }

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let radius = Double(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - radius + 0.5
                let dy = Double(y) - radius + 0.5
                let dist = (dx * dx + dy * dy).squareRoot()
                let t = (radius - dist) / bandPx
                let alpha: Double
                if t >= 1 {
                    alpha = 1
                } else {
                    let n = noise(Double(x) / Double(size - 1), Double(y) / Double(size - 1))
                    alpha = min(1, max(0, (t - n * 0.9) * 2.5))
                }
                let p = (y * size + x) * 4
                let a8 = UInt8(alpha * 255)
                bytes[p] = a8
                bytes[p + 1] = a8
                bytes[p + 2] = a8
                bytes[p + 3] = a8
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    private func thanosAsh(vanish: Bool, onPet: NSView, direction: CGVector?, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 1.25
        beginEffect(onPet: onPet, padding: 40, fallback: completion) { [weak self] snap in
            self?.runThanosAsh(
                vanish: vanish,
                onPet: onPet,
                snapshot: snap,
                direction: direction,
                duration: duration,
                completion: completion
            )
        }
    }

    private func runThanosAsh(
        vanish: Bool,
        onPet: NSView,
        snapshot: CGImage,
        direction: CGVector?,
        duration: CFTimeInterval,
        completion: @escaping () -> Void
    ) {
        let rect = petRect(in: onPet)
        // Dissolve front travels along the trip's horizontal component.
        let sweepRight = (direction?.dx ?? 1) >= 0

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snapshot
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer
        liveContentLayers.append(petLayer)

        let shell = addEnergyShell(rect: rect, snapshot: snapshot)
        flashShell(shell, vanish: vanish, duration: duration)
        if !vanish {
            addConvergenceCue(rect: rect, color: Self.ashWarm, duration: duration)
        }

        // Per-pixel noise dissolve: a pre-generated chunky noise band slides
        // across the snapshot, eating it away in crumbs instead of a smooth
        // gradient wipe. Layout of the mask image (opaqueOnRight):
        //   [clear W][noise band B][opaque W]  — sliding it moves the front.
        let bandWidth = max(24, rect.width * 0.38)
        let maskWidth = rect.width * 2 + bandWidth
        let opaqueOnRight = (vanish && sweepRight) || (!vanish && !sweepRight)
        let mask = CALayer()
        mask.contentsGravity = .resize
        mask.contents = Self.makeNoiseBandMask(
            petSize: rect.size,
            band: bandWidth,
            opaqueOnRight: opaqueOnRight
        )
        // Sweep-right slides the image rightwards, sweep-left leftwards;
        // combined with the image orientation this covers all four cases
        // (vanish starts covered, appear starts clear).
        let startOriginX: CGFloat = sweepRight ? -(rect.width + bandWidth) : 0
        let endOriginX: CGFloat = sweepRight ? 0 : -(rect.width + bandWidth)
        mask.frame = CGRect(x: startOriginX, y: -2, width: maskWidth, height: rect.height + 4)
        petLayer.mask = mask

        let startPosX = startOriginX + maskWidth / 2
        let endPosX = endOriginX + maskWidth / 2
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = startPosX
        slide.toValue = endPosX
        slide.duration = duration * 0.9
        slide.timingFunction = Self.easeInOut
        slide.fillMode = .forwards
        slide.isRemovedOnCompletion = false
        mask.add(slide, forKey: "wipe")
        mask.position = CGPoint(x: endPosX, y: rect.height / 2)

        // Dust emits from a thin vertical front that travels with the wipe
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .line
        emitter.emitterMode = .outline
        emitter.emitterSize = CGSize(width: 0, height: rect.height * 0.88)
        emitter.renderMode = .oldestLast
        let startX = sweepRight ? rect.minX + 4 : rect.maxX - 4
        let endX = sweepRight ? rect.maxX - 4 : rect.minX + 4
        emitter.emitterPosition = CGPoint(x: startX, y: rect.midY)
        overlay.addSublayer(emitter)

        let frontMove = CABasicAnimation(keyPath: "emitterPosition")
        frontMove.fromValue = CGPoint(x: startX, y: rect.midY)
        frontMove.toValue = CGPoint(x: endX, y: rect.midY)
        frontMove.duration = duration * 0.9
        frontMove.timingFunction = Self.easeInOut
        frontMove.fillMode = .forwards
        frontMove.isRemovedOnCompletion = false
        emitter.add(frontMove, forKey: "front")
        emitter.emitterPosition = CGPoint(x: endX, y: rect.midY)

        let flake = CAEmitterCell()
        flake.contents = Self.softDust
        flake.birthRate = 180
        flake.lifetime = Float(duration * 0.85)
        flake.velocity = vanish ? 28 : -22
        flake.velocityRange = 18
        flake.yAcceleration = vanish ? 42 : -18
        flake.xAcceleration = (vanish ? 12 : -8) * (sweepRight ? 1 : -1)
        if vanish {
            flake.emissionLongitude = sweepRight ? (.pi * 0.15) : (.pi * 0.85)
        } else {
            flake.emissionLongitude = sweepRight ? (.pi * 0.85) : (.pi * 0.15)
        }
        flake.emissionRange = .pi * 0.45
        flake.scale = 0.22
        flake.scaleRange = 0.18
        flake.alphaSpeed = -1.0
        flake.color = Self.ashWarm.cgColor
        flake.redRange = 0.12
        flake.greenRange = 0.1
        flake.blueRange = 0.1

        let dust = CAEmitterCell()
        dust.contents = Self.softSpark
        dust.birthRate = 90
        dust.lifetime = Float(duration * 0.65)
        dust.velocity = vanish ? 45 : -35
        dust.yAcceleration = vanish ? 25 : -12
        dust.emissionLongitude = sweepRight ? 0 : .pi
        dust.emissionRange = .pi * 0.7
        dust.scale = 0.12
        dust.alphaSpeed = -1.4
        dust.color = Self.ashCool.cgColor

        // Chunky debris: fewer, larger, tumbling — sells "matter", not fog.
        let debris = CAEmitterCell()
        debris.contents = Self.softDust
        debris.birthRate = 26
        debris.lifetime = Float(duration * 0.7)
        debris.velocity = vanish ? 36 : -26
        debris.velocityRange = 20
        debris.yAcceleration = vanish ? 30 : -14
        debris.xAcceleration = (vanish ? 10 : -6) * (sweepRight ? 1 : -1)
        debris.emissionLongitude = flake.emissionLongitude
        debris.emissionRange = .pi * 0.4
        debris.scale = 0.34
        debris.scaleRange = 0.16
        debris.spin = 1.6
        debris.spinRange = 2.4
        debris.alphaSpeed = -0.9
        debris.color = Self.ashWarm.withAlphaComponent(0.9).cgColor

        emitter.emitterCells = [flake, dust, debris]

        // Burning edge: a thin ember-tinted band rides the dissolve front,
        // flickering — the dissolve looks driven by something, not just
        // wiped by a mask.
        let edge = CAGradientLayer()
        edge.bounds = CGRect(x: 0, y: 0, width: 26, height: rect.height + 4)
        edge.startPoint = CGPoint(x: 0, y: 0.5)
        edge.endPoint = CGPoint(x: 1, y: 0.5)
        edge.colors = [
            Self.gold.withAlphaComponent(0).cgColor,
            Self.gold.withAlphaComponent(0.5).cgColor,
            Self.goldSoft.withAlphaComponent(0.18).cgColor,
            Self.gold.withAlphaComponent(0).cgColor
        ]
        edge.locations = [0, 0.45, 0.6, 1]
        edge.opacity = 0
        edge.position = CGPoint(x: startX, y: rect.midY)
        overlay.addSublayer(edge)

        let edgeMove = CABasicAnimation(keyPath: "position.x")
        edgeMove.fromValue = startX
        edgeMove.toValue = endX
        edgeMove.duration = duration * 0.9
        edgeMove.timingFunction = Self.easeInOut
        edgeMove.fillMode = .forwards
        edgeMove.isRemovedOnCompletion = false
        edge.add(edgeMove, forKey: "ride")
        edge.position = CGPoint(x: endX, y: rect.midY)

        let edgeGlow = CAKeyframeAnimation(keyPath: "opacity")
        edgeGlow.values = [0, 0.85, 0.72, 0.9, 0.68, 0]
        edgeGlow.keyTimes = [0, 0.15, 0.4, 0.6, 0.85, 1]
        edgeGlow.duration = duration * 0.9
        edgeGlow.fillMode = .both
        edgeGlow.isRemovedOnCompletion = false
        edge.add(edgeGlow, forKey: "o")

        // Follow-through: a soft settle once the body completes.
        if !vanish {
            let settle = CAKeyframeAnimation(keyPath: "transform.scale")
            settle.values = [1.0, 1.0, 1.012, 1.0]
            settle.keyTimes = [0, 0.82, 0.92, 1]
            settle.duration = duration
            settle.fillMode = .both
            settle.isRemovedOnCompletion = false
            petLayer.add(settle, forKey: "settle")
        }

        let stop = DispatchWorkItem { emitter.birthRate = 0 }
        particleStopWorkItem = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.72, execute: stop)

        // Tail: flakes live 0.85·d and are born up to 0.72·d — let them settle.
        if !vanish {
            addLandingAmbience(rect: rect, duration: duration)
        }

        finish(after: duration, tail: 0.75, onPet: onPet, completion: completion)
    }

    // MARK: - CRT switch-off (beam)

    private func lightBeam(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        // Old-TV power-off: the picture collapses to a blazing scanline,
        // then a dot; power-on plays it backwards. 老电视开关机。
        let duration: CFTimeInterval = 0.95
        beginEffect(onPet: onPet, padding: 48, fallback: completion) { [weak self] snap in
            self?.runLightBeam(vanish: vanish, onPet: onPet, snapshot: snap, duration: duration, completion: completion)
        }
    }

    private func runLightBeam(vanish: Bool, onPet: NSView, snapshot: CGImage, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let t0 = CACurrentMediaTime()

        // Everything that IS the cat collapses together inside one group.
        let group = CALayer()
        group.frame = rect
        overlay.addSublayer(group)
        stagingLayer = group

        let petLayer = CALayer()
        petLayer.frame = group.bounds
        petLayer.contents = snapshot
        group.addSublayer(petLayer)
        liveContentLayers.append(petLayer)

        // Over-bright silhouette: the picture burns as the tube dies/wakes.
        let shell = CALayer()
        shell.frame = group.bounds
        shell.backgroundColor = NSColor.white.cgColor
        let shellMask = CALayer()
        shellMask.frame = group.bounds
        shellMask.contents = snapshot
        shell.mask = shellMask
        shell.opacity = 0
        group.addSublayer(shell)
        liveContentLayers.append(shellMask)

        // Scanlines clipped to the cat's own alpha.
        let scan = CAGradientLayer()
        scan.frame = group.bounds
        var scanColors: [CGColor] = []
        var scanLocations: [NSNumber] = []
        for i in 0..<18 {
            let base = Double(i) / 18.0
            scanColors.append(NSColor.black.withAlphaComponent(0).cgColor)
            scanColors.append(NSColor.black.withAlphaComponent(0.32).cgColor)
            scanLocations.append(NSNumber(value: base))
            scanLocations.append(NSNumber(value: base + 0.028))
        }
        scan.colors = scanColors
        scan.locations = scanLocations
        scan.startPoint = CGPoint(x: 0.5, y: 0)
        scan.endPoint = CGPoint(x: 0.5, y: 1)
        let scanMask = CALayer()
        scanMask.frame = group.bounds
        scanMask.contents = snapshot
        scan.mask = scanMask
        scan.opacity = 0
        group.addSublayer(scan)
        liveContentLayers.append(scanMask)

        if !vanish {
            addConvergenceCue(rect: rect, color: Self.beamCore, duration: duration)
        }

        // —— The collapse / ignition itself ——
        let lineT = CATransform3DMakeScale(1.08, 0.015, 1)
        let dotT = CATransform3DMakeScale(0.03, 0.015, 1)
        let bulgeT = CATransform3DMakeScale(1.0, 1.06, 1)
        let overT = CATransform3DMakeScale(1.0, 1.04, 1)

        let crt = CAKeyframeAnimation(keyPath: "transform")
        if vanish {
            crt.values = [
                NSValue(caTransform3D: CATransform3DIdentity),
                NSValue(caTransform3D: bulgeT),
                NSValue(caTransform3D: lineT),
                NSValue(caTransform3D: lineT),
                NSValue(caTransform3D: dotT),
                NSValue(caTransform3D: dotT)
            ]
            crt.keyTimes = [0, 0.2, 0.45, 0.56, 0.74, 1]
            crt.timingFunctions = [
                Self.easeOutSoft, Self.easeInSoft, Self.easeInOut, Self.easeInSoft, Self.easeInOut
            ]
        } else {
            crt.values = [
                NSValue(caTransform3D: dotT),
                NSValue(caTransform3D: dotT),
                NSValue(caTransform3D: lineT),
                NSValue(caTransform3D: lineT),
                NSValue(caTransform3D: overT),
                NSValue(caTransform3D: CATransform3DIdentity)
            ]
            crt.keyTimes = [0, 0.1, 0.3, 0.42, 0.82, 1]
            crt.timingFunctions = [
                Self.easeInOut, Self.easeOutSoft, Self.easeInOut, Self.easeOutSoft, Self.easeInOut
            ]
        }
        crt.beginTime = t0
        crt.duration = duration
        crt.fillMode = .both
        crt.isRemovedOnCompletion = false
        group.add(crt, forKey: "crt")
        group.transform = vanish ? dotT : CATransform3DIdentity

        // Horizontal glitch jitter right around the collapse/ignition.
        let jitter = CAKeyframeAnimation(keyPath: "position.x")
        if vanish {
            jitter.values = [center.x, center.x, center.x - 3, center.x + 2.5, center.x, center.x]
            jitter.keyTimes = [0, 0.28, 0.36, 0.44, 0.5, 1]
        } else {
            jitter.values = [center.x, center.x, center.x + 3, center.x - 2.5, center.x, center.x]
            jitter.keyTimes = [0, 0.3, 0.38, 0.46, 0.54, 1]
        }
        jitter.beginTime = t0
        jitter.duration = duration
        jitter.fillMode = .both
        jitter.isRemovedOnCompletion = false
        group.add(jitter, forKey: "jitter")

        let groupFade = CAKeyframeAnimation(keyPath: "opacity")
        groupFade.values = vanish ? [1, 1, 0, 0] : [0, 1, 1]
        groupFade.keyTimes = vanish ? [0, 0.8, 0.92, 1] : [0, 0.12, 1]
        groupFade.beginTime = t0
        groupFade.duration = duration
        groupFade.fillMode = .both
        groupFade.isRemovedOnCompletion = false
        group.add(groupFade, forKey: "o")
        group.opacity = vanish ? 0 : 1

        let burn = CAKeyframeAnimation(keyPath: "opacity")
        if vanish {
            burn.values = [0, 0.3, 0.95, 0.95, 0, 0]
            burn.keyTimes = [0, 0.25, 0.45, 0.72, 0.9, 1]
        } else {
            burn.values = [0.95, 0.9, 0.35, 0]
            burn.keyTimes = [0, 0.42, 0.75, 1]
        }
        burn.beginTime = t0
        burn.duration = duration
        burn.fillMode = .both
        burn.isRemovedOnCompletion = false
        shell.add(burn, forKey: "burn")

        let scanOp = CAKeyframeAnimation(keyPath: "opacity")
        if vanish {
            scanOp.values = [0, 0.3, 0.16, 0.34, 0, 0]
            scanOp.keyTimes = [0, 0.18, 0.3, 0.42, 0.55, 1]
        } else {
            scanOp.values = [0, 0, 0.34, 0.18, 0.28, 0]
            scanOp.keyTimes = [0, 0.25, 0.4, 0.55, 0.75, 1]
        }
        scanOp.beginTime = t0
        scanOp.duration = duration
        scanOp.fillMode = .both
        scanOp.isRemovedOnCompletion = false
        scan.add(scanOp, forKey: "o")

        let scanRoll = CABasicAnimation(keyPath: "position.y")
        scanRoll.fromValue = group.bounds.midY - 5
        scanRoll.toValue = group.bounds.midY + 5
        scanRoll.beginTime = t0
        scanRoll.duration = duration
        scanRoll.fillMode = .both
        scanRoll.isRemovedOnCompletion = false
        scan.add(scanRoll, forKey: "roll")

        // —— Free-standing flashes in the overlay (unscaled) ——
        let lineFlash = CAGradientLayer()
        lineFlash.bounds = CGRect(x: 0, y: 0, width: rect.width * 1.35, height: 4)
        lineFlash.position = center
        lineFlash.startPoint = CGPoint(x: 0, y: 0.5)
        lineFlash.endPoint = CGPoint(x: 1, y: 0.5)
        lineFlash.colors = [
            Self.beamCore.withAlphaComponent(0).cgColor,
            Self.beamCore.withAlphaComponent(0.95).cgColor,
            NSColor.white.withAlphaComponent(0.95).cgColor,
            Self.beamCore.withAlphaComponent(0.95).cgColor,
            Self.beamCore.withAlphaComponent(0).cgColor
        ]
        lineFlash.locations = [0, 0.2, 0.5, 0.8, 1]
        lineFlash.shadowColor = Self.beamCore.cgColor
        lineFlash.shadowRadius = 8
        lineFlash.shadowOpacity = 0.9
        lineFlash.shadowOffset = .zero
        lineFlash.opacity = 0
        overlay.addSublayer(lineFlash)

        let lineOp = CAKeyframeAnimation(keyPath: "opacity")
        if vanish {
            lineOp.values = [0, 0, 0.95, 0.8, 0, 0]
            lineOp.keyTimes = [0, 0.42, 0.5, 0.68, 0.82, 1]
        } else {
            lineOp.values = [0, 0, 0.9, 0.75, 0, 0]
            lineOp.keyTimes = [0, 0.08, 0.3, 0.42, 0.55, 1]
        }
        lineOp.beginTime = t0
        lineOp.duration = duration
        lineOp.fillMode = .both
        lineOp.isRemovedOnCompletion = false
        lineFlash.add(lineOp, forKey: "o")

        // The dying / waking dot.
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        dot.contents = Self.softGlow
        dot.position = center
        dot.opacity = 0
        overlay.addSublayer(dot)

        let dotOp = CAKeyframeAnimation(keyPath: "opacity")
        if vanish {
            dotOp.values = [0, 0, 1, 0]
            dotOp.keyTimes = [0, 0.72, 0.8, 1]
        } else {
            dotOp.values = [1, 0.6, 0, 0]
            dotOp.keyTimes = [0, 0.12, 0.28, 1]
        }
        dotOp.beginTime = t0
        dotOp.duration = duration
        dotOp.fillMode = .both
        dotOp.isRemovedOnCompletion = false
        dot.add(dotOp, forKey: "o")

        if !vanish {
            addLandingAmbience(rect: rect, duration: duration)
        }

        finish(after: duration, tail: 0.3, onPet: onPet, completion: completion)
    }

    // MARK: - Blink

    private func flashBlink(vanish: Bool, onPet: NSView, direction: CGVector?, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.5
        beginEffect(onPet: onPet, padding: 88, fallback: completion) { [weak self] snap in
            self?.runFlashBlink(
                vanish: vanish,
                onPet: onPet,
                snapshot: snap,
                direction: direction,
                duration: duration,
                completion: completion
            )
        }
    }

    private func runFlashBlink(
        vanish: Bool,
        onPet: NSView,
        snapshot: CGImage,
        direction: CGVector?,
        duration: CFTimeInterval,
        completion: @escaping () -> Void
    ) {
        let rect = petRect(in: onPet)
        let dir = direction ?? CGVector(dx: 0, dy: 1)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dash = min(64, rect.width * 0.45)
        func along(_ s: CGFloat) -> CGPoint {
            CGPoint(x: center.x + dir.dx * s, y: center.y + dir.dy * s)
        }

        // Flash-step: the snapshot rides inside a replicator whose delayed
        // instances replay the dash slightly behind — a few CRISP ghosts
        // (wider delay, cool tint) instead of a tight blurry smear.
        let replicator = CAReplicatorLayer()
        replicator.frame = overlay.bounds
        replicator.instanceCount = 4
        replicator.instanceDelay = 0.045
        replicator.instanceAlphaOffset = -0.26
        replicator.instanceRedOffset = -0.05
        replicator.instanceGreenOffset = -0.02
        replicator.instanceBlueOffset = 0.04
        overlay.addSublayer(replicator)

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snapshot
        petLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        petLayer.position = center
        replicator.addSublayer(petLayer)
        stagingLayer = replicator
        liveContentLayers.append(petLayer)

        // Dash out towards the destination / slide in from the origin side.
        let move = CAKeyframeAnimation(keyPath: "position")
        if vanish {
            move.values = [center, along(-8), along(dash)].map { NSValue(point: $0) }
            move.keyTimes = [0, 0.3, 1]
            move.timingFunctions = [Self.easeOutSoft, Self.easeInSoft]
        } else {
            move.values = [along(-dash), along(6), center].map { NSValue(point: $0) }
            move.keyTimes = [0, 0.72, 1]
            move.timingFunctions = [Self.easeOutSoft, Self.easeInOut]
        }
        move.duration = duration
        move.fillMode = .both
        move.isRemovedOnCompletion = false
        petLayer.add(move, forKey: "dash")
        petLayer.position = vanish ? along(dash) : center

        // White silhouette flash: a white layer masked by the snapshot's
        // alpha, so the CAT ITSELF flashes to light — the anime tell for a
        // flash-step — instead of a flat glow blob over everything.
        let silhouette = CALayer()
        silhouette.frame = petLayer.bounds
        silhouette.backgroundColor = NSColor.white.cgColor
        let silhouetteMask = CALayer()
        silhouetteMask.frame = petLayer.bounds
        silhouetteMask.contents = snapshot
        silhouette.mask = silhouetteMask
        silhouette.opacity = 0
        petLayer.addSublayer(silhouette)
        liveContentLayers.append(silhouetteMask)

        let flashAnim = CAKeyframeAnimation(keyPath: "opacity")
        if vanish {
            // A snap of light right before the dash launches.
            flashAnim.values = [0, 0.95, 0]
            flashAnim.keyTimes = [0, 0.4, 1]
            flashAnim.duration = 0.16
        } else {
            // Arrives AS light, then anneals into the real cat.
            flashAnim.values = [1, 1, 0]
            flashAnim.keyTimes = [0, 0.5, 1]
            flashAnim.duration = duration * 0.85
        }
        flashAnim.fillMode = .both
        flashAnim.isRemovedOnCompletion = false
        silhouette.add(flashAnim, forKey: "flash")

        // Speed lines along the dash direction: drawn fast, consumed fast.
        let perp = CGVector(dx: -dir.dy, dy: dir.dx)
        let lineSpecs: [(offset: CGFloat, lead: CGFloat, delay: CFTimeInterval)] = [
            (-rect.height * 0.22, 0.9, 0.02),
            (rect.height * 0.06, 1.0, 0.0),
            (rect.height * 0.3, 0.72, 0.045)
        ]
        for spec in lineSpecs {
            let base = CGPoint(
                x: center.x + perp.dx * spec.offset,
                y: center.y + perp.dy * spec.offset
            )
            let span = (dash + rect.width * 0.5) * spec.lead
            let startP: CGPoint
            let endP: CGPoint
            if vanish {
                startP = CGPoint(x: base.x - dir.dx * span * 0.4, y: base.y - dir.dy * span * 0.4)
                endP = CGPoint(x: base.x + dir.dx * span, y: base.y + dir.dy * span)
            } else {
                startP = CGPoint(x: base.x - dir.dx * span, y: base.y - dir.dy * span)
                endP = CGPoint(x: base.x + dir.dx * span * 0.4, y: base.y + dir.dy * span * 0.4)
            }
            let linePath = CGMutablePath()
            linePath.move(to: startP)
            linePath.addLine(to: endP)
            let line = CAShapeLayer()
            line.path = linePath
            line.strokeColor = Self.beamCore.withAlphaComponent(0.85).cgColor
            line.fillColor = nil
            line.lineWidth = 1.6
            line.lineCap = .round
            line.strokeEnd = 0
            overlay.addSublayer(line)

            let lineBegin = CACurrentMediaTime() + (vanish ? duration * 0.22 : 0) + spec.delay
            let drawLine = CABasicAnimation(keyPath: "strokeEnd")
            drawLine.fromValue = 0
            drawLine.toValue = 1
            drawLine.beginTime = lineBegin
            drawLine.duration = 0.1
            drawLine.timingFunction = Self.easeOutSoft
            drawLine.fillMode = .both
            drawLine.isRemovedOnCompletion = false
            line.add(drawLine, forKey: "draw")
            line.strokeEnd = 1

            let chaseLine = CABasicAnimation(keyPath: "strokeStart")
            chaseLine.fromValue = 0
            chaseLine.toValue = 1
            chaseLine.beginTime = lineBegin + 0.06
            chaseLine.duration = 0.12
            chaseLine.timingFunction = Self.easeInSoft
            chaseLine.fillMode = .both
            chaseLine.isRemovedOnCompletion = false
            line.add(chaseLine, forKey: "chase")
            line.strokeStart = 1
        }

        // Barely-there scale breathing — the step reads through motion and
        // light, not through the cat visibly shrinking.
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        if vanish {
            scale.values = [1.0, 1.03, 0.97]
            scale.keyTimes = [0, 0.3, 1]
            scale.timingFunctions = [Self.easeOutSoft, Self.easeInSoft]
        } else {
            scale.values = [0.97, 1.02, 1.0]
            scale.keyTimes = [0, 0.72, 1]
            scale.timingFunctions = [Self.easeOutSoft, Self.easeInOut]
        }
        scale.duration = duration
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        petLayer.add(scale, forKey: "s")

        // Vanish: stay solid through most of the dash, then snap away.
        // Appear: fade up fast so the silhouette carries the entrance.
        let fade = CABasicAnimation(keyPath: "opacity")
        if vanish {
            fade.fromValue = 1
            fade.toValue = 0
            fade.beginTime = CACurrentMediaTime() + duration * 0.5
            fade.duration = duration * 0.42
            fade.timingFunction = Self.easeInSoft
        } else {
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = duration * 0.35
            fade.timingFunction = Self.easeOutSoft
        }
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        petLayer.add(fade, forKey: "o")
        petLayer.opacity = vanish ? 0 : 1
        petLayer.transform = CATransform3DMakeScale(vanish ? 0.97 : 1.0, vanish ? 0.97 : 1.0, 1)

        // Tail covers the replicator ghosts finishing their delayed replay.
        if !vanish {
            addLandingAmbience(rect: rect, duration: duration)
        }

        finish(after: duration, tail: 0.2, onPet: onPet, completion: completion)
    }
}
