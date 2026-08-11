import AppKit
import DesktopPetCore
import QuartzCore

final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

    var setEffectPadding: ((CGFloat) -> Void)?

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
        host.layer?.addSublayer(overlay)
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

    func playVanish(style: TeleportEffectStyle, onPet: NSView, completion: @escaping () -> Void) {
        prepare(onPet: onPet)
        switch style {
        case .portal: strangePortal(vanish: true, onPet: onPet, completion: completion)
        case .warp: genie(vanish: true, onPet: onPet, completion: completion)
        case .particles: thanosAsh(vanish: true, onPet: onPet, completion: completion)
        case .beam: lightBeam(vanish: true, onPet: onPet, completion: completion)
        case .blink: flashBlink(vanish: true, onPet: onPet, completion: completion)
        case .mist: softMist(vanish: true, onPet: onPet, completion: completion)
        }
    }

    func playAppear(style: TeleportEffectStyle, onPet: NSView, completion: @escaping () -> Void) {
        prepare(onPet: onPet)
        switch style {
        case .portal: strangePortal(vanish: false, onPet: onPet, completion: completion)
        case .warp: genie(vanish: false, onPet: onPet, completion: completion)
        case .particles: thanosAsh(vanish: false, onPet: onPet, completion: completion)
        case .beam: lightBeam(vanish: false, onPet: onPet, completion: completion)
        case .blink: flashBlink(vanish: false, onPet: onPet, completion: completion)
        case .mist: softMist(vanish: false, onPet: onPet, completion: completion)
        }
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
        overlay.frame = onPet.bounds
        if overlay.superlayer !== onPet.layer {
            onPet.layer?.addSublayer(overlay)
        }
    }

    private func teardownStaging() {
        stagingLayer?.removeFromSuperlayer()
        stagingLayer = nil
        clearOverlay()
    }

    private func clearOverlay() {
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        overlay.removeAllAnimations()
    }

    private func finish(after duration: CFTimeInterval, onPet: NSView, completion: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.teardownStaging()
            self.setEffectPadding?(0)
            onPet.layer?.mask = nil
            onPet.alphaValue = 1
            onPet.layer?.opacity = 1
            onPet.layer?.transform = CATransform3DIdentity
            if let pet = onPet as? PetContentView, let saved = self.savedImage {
                pet.image = saved
            }
            self.savedImage = nil
            completion()
        }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func snapshot(_ view: NSView) -> (NSImage, CGImage)? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { return nil }
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return (image, cg)
    }

    private func petRect(in view: NSView) -> CGRect {
        (view as? PetContentView)?.imageDrawRect ?? view.bounds
    }

    private func hideLivePet(_ view: NSView) {
        if let pet = view as? PetContentView {
            savedImage = pet.image
            pet.image = nil
        } else {
            view.alphaValue = 0
        }
    }

    private func afterPadding(_ onPet: NSView, _ body: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlay.frame = onPet.bounds
            body()
        }
    }

    // MARK: - Portal (Strange, photographic)

    private func strangePortal(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.92
        setEffectPadding?(64)
        afterPadding(onPet) { [weak self] in
            self?.runStrangePortal(vanish: vanish, onPet: onPet, duration: duration, completion: completion)
        }
    }

    private func runStrangePortal(vanish: Bool, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        guard let snap = snapshot(onPet) else {
            finish(after: 0.05, onPet: onPet, completion: completion)
            return
        }
        hideLivePet(onPet)

        let center = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.02)
        // Slightly elliptical — reads as a portal plane, not a flat sticker
        let rx = min(rect.width, rect.height) * 0.52
        let ry = rx * 0.88
        let spinDir: CGFloat = vanish ? 1 : -1
        let t0 = CACurrentMediaTime()

        // —— Void disc (dark throat of the portal) ——
        let voidLayer = CAShapeLayer()
        voidLayer.bounds = CGRect(x: 0, y: 0, width: rx * 2.1, height: ry * 2.1)
        voidLayer.position = center
        voidLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        voidLayer.path = CGPath(ellipseIn: voidLayer.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        voidLayer.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        voidLayer.opacity = 0
        overlay.addSublayer(voidLayer)

        let voidOp = CAKeyframeAnimation(keyPath: "opacity")
        voidOp.values = vanish ? [0, 0.7, 0.85, 0] : [0, 0.75, 0.55, 0]
        voidOp.keyTimes = [0, 0.2, 0.65, 1]
        voidOp.duration = duration
        voidLayer.add(voidOp, forKey: "o")

        let voidBreath = CAKeyframeAnimation(keyPath: "transform.scale")
        voidBreath.values = vanish ? [0.35, 1.0, 0.9] : [0.3, 1.05, 1.0]
        voidBreath.keyTimes = [0, 0.35, 1]
        voidBreath.duration = duration
        voidBreath.timingFunction = Self.easeOutSoft
        voidLayer.add(voidBreath, forKey: "s")

        // —— Warm volumetric glow behind the ring ——
        let haze = CALayer()
        haze.contents = Self.softGlow
        haze.contentsGravity = .resizeAspectFill
        haze.bounds = CGRect(x: 0, y: 0, width: rx * 3.2, height: ry * 3.0)
        haze.position = center
        haze.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        haze.opacity = 0
        overlay.addSublayer(haze)

        let hazeTint = CALayer()
        hazeTint.bounds = haze.bounds
        hazeTint.position = center
        hazeTint.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        hazeTint.backgroundColor = Self.gold.withAlphaComponent(0.22).cgColor
        hazeTint.cornerRadius = min(haze.bounds.width, haze.bounds.height) * 0.5
        hazeTint.opacity = 0
        overlay.insertSublayer(hazeTint, below: haze)

        let hazeOp = CAKeyframeAnimation(keyPath: "opacity")
        hazeOp.values = vanish ? [0, 0.5, 0.65, 0.2, 0] : [0, 0.35, 0.6, 0.25, 0]
        hazeOp.keyTimes = [0, 0.15, 0.4, 0.75, 1]
        hazeOp.duration = duration
        haze.add(hazeOp, forKey: "o")
        hazeTint.add(hazeOp, forKey: "o")

        // —— Pet sucked through iris (delayed until ring is open) ——
        let petLayer = CALayer()
        petLayer.bounds = CGRect(origin: .zero, size: rect.size)
        petLayer.position = center
        petLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        petLayer.contents = snap.1
        petLayer.contentsGravity = .resize
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer

        let iris = CAShapeLayer()
        iris.bounds = petLayer.bounds
        iris.position = CGPoint(x: petLayer.bounds.midX, y: petLayer.bounds.midY)
        iris.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let irisPad: CGFloat = 4
        iris.path = CGPath(
            ellipseIn: petLayer.bounds.insetBy(dx: -irisPad, dy: -irisPad),
            transform: nil
        )
        petLayer.mask = iris

        let suckDelay = vanish ? duration * 0.18 : 0.0
        let suckDur = duration * 0.62

        let irisScale = CABasicAnimation(keyPath: "transform.scale")
        irisScale.fromValue = vanish ? 1.05 : 0.02
        irisScale.toValue = vanish ? 0.02 : 1.05
        irisScale.beginTime = t0 + suckDelay
        irisScale.duration = suckDur
        irisScale.timingFunction = vanish ? Self.easeInSoft : Self.easeOutSoft
        irisScale.fillMode = .both
        irisScale.isRemovedOnCompletion = false
        iris.add(irisScale, forKey: "iris")
        iris.transform = CATransform3DMakeScale(vanish ? 0.02 : 1.05, vanish ? 0.02 : 1.05, 1)

        var endT = CATransform3DMakeScale(vanish ? 0.12 : 1.0, vanish ? 0.12 : 1.0, 1)
        endT = CATransform3DRotate(endT, spinDir * 0.22, 0, 0, 1)
        let startT: CATransform3D = vanish
            ? CATransform3DIdentity
            : CATransform3DScale(CATransform3DMakeRotation(-spinDir * 0.22, 0, 0, 1), 0.12, 0.12, 1)
        if !vanish { petLayer.transform = startT }

        let suck = CABasicAnimation(keyPath: "transform")
        suck.fromValue = startT
        suck.toValue = vanish ? endT : CATransform3DIdentity
        suck.beginTime = t0 + suckDelay
        suck.duration = suckDur
        suck.timingFunction = vanish ? Self.easeInSoft : Self.easeOutSoft
        suck.fillMode = .both
        suck.isRemovedOnCompletion = false
        petLayer.add(suck, forKey: "suck")
        petLayer.transform = vanish ? endT : CATransform3DIdentity

        let petFade = CABasicAnimation(keyPath: "opacity")
        petFade.fromValue = vanish ? 1 : 0.15
        petFade.toValue = vanish ? 0 : 1
        petFade.beginTime = t0 + suckDelay + (vanish ? suckDur * 0.55 : 0)
        petFade.duration = vanish ? suckDur * 0.45 : suckDur * 0.5
        petFade.timingFunction = Self.easeInOut
        petFade.fillMode = .both
        petFade.isRemovedOnCompletion = false
        petLayer.add(petFade, forKey: "fade")
        petLayer.opacity = vanish ? 0 : 1

        // —— Multi-layer gold ring (all rotate around true center) ——
        addPortalRingStack(
            center: center,
            rx: rx,
            ry: ry,
            spinDir: spinDir,
            vanish: vanish,
            duration: duration,
            t0: t0
        )

        // —— Tangential sparks riding the rim ——
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = center
        emitter.emitterShape = .circle
        emitter.emitterMode = .outline
        emitter.emitterSize = CGSize(width: rx * 2.04, height: ry * 2.04)
        emitter.renderMode = .additive
        emitter.birthRate = 1

        // Hot sparks — short, mostly tangential
        let spark = CAEmitterCell()
        spark.contents = Self.softSpark
        spark.birthRate = 95
        spark.lifetime = 0.42
        spark.lifetimeRange = 0.12
        spark.velocity = 14
        spark.velocityRange = 10
        spark.scale = 0.16
        spark.scaleRange = 0.08
        spark.scaleSpeed = -0.25
        spark.alphaSpeed = -2.0
        spark.color = Self.gold.cgColor
        spark.redRange = 0.06
        spark.greenRange = 0.05
        spark.blueRange = 0.02
        // Tangential sweep + slight outward
        spark.emissionLongitude = spinDir > 0 ? (.pi / 2) : (-.pi / 2)
        spark.emissionRange = .pi * 0.35

        // Soft ember glow clinging to the rim
        let ember = CAEmitterCell()
        ember.contents = Self.softDust
        ember.birthRate = 28
        ember.lifetime = 0.7
        ember.velocity = 4
        ember.velocityRange = 3
        ember.scale = 0.32
        ember.scaleRange = 0.12
        ember.alphaSpeed = -1.2
        ember.color = Self.goldSoft.withAlphaComponent(0.75).cgColor
        ember.emissionRange = .pi * 2

        emitter.emitterCells = [spark, ember]
        overlay.addSublayer(emitter)

        // Emitter ring breathes with the portal
        let emitScale = CAKeyframeAnimation(keyPath: "emitterSize")
        let open = NSValue(size: CGSize(width: rx * 2.04, height: ry * 2.04))
        let mid = NSValue(size: CGSize(width: rx * 2.2, height: ry * 2.2))
        let closed = NSValue(size: CGSize(width: rx * 1.1, height: ry * 1.1))
        emitScale.values = vanish ? [closed, open, mid, open] : [closed, mid, open, open]
        emitScale.keyTimes = [0, 0.3, 0.55, 1]
        emitScale.duration = duration
        emitter.add(emitScale, forKey: "sz")

        let stop = DispatchWorkItem { emitter.birthRate = 0 }
        particleStopWorkItem = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.68, execute: stop)

        finish(after: duration, onPet: onPet, completion: completion)
    }

    /// Concentric gold rims + rune ticks, all pivoted on `center`.
    private func addPortalRingStack(
        center: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        spinDir: CGFloat,
        vanish: Bool,
        duration: CFTimeInterval,
        t0: CFTimeInterval
    ) {
        struct RimSpec {
            var sx: CGFloat
            var sy: CGFloat
            var lineWidth: CGFloat
            var color: NSColor
            var alpha: CGFloat
            var shadowRadius: CGFloat
            var shadowOpacity: Float
            var spinTurns: CGFloat
            var dash: [NSNumber]?
        }

        let specs: [RimSpec] = [
            // Outer soft bloom stroke
            RimSpec(sx: 1.14, sy: 1.14, lineWidth: 5.0, color: Self.goldSoft, alpha: 0.22,
                    shadowRadius: 22, shadowOpacity: 0.7, spinTurns: 0.55, dash: nil),
            // Mid solid energy rim
            RimSpec(sx: 1.0, sy: 1.0, lineWidth: 2.2, color: Self.gold, alpha: 0.95,
                    shadowRadius: 10, shadowOpacity: 0.9, spinTurns: 1.15, dash: nil),
            // Inner hot filament
            RimSpec(sx: 0.92, sy: 0.92, lineWidth: 1.1, color: Self.goldSoft, alpha: 0.9,
                    shadowRadius: 6, shadowOpacity: 0.8, spinTurns: 1.4, dash: nil),
            // Rune-like dashed band (Strange calligraphy feel)
            RimSpec(sx: 1.06, sy: 1.06, lineWidth: 1.6, color: Self.gold, alpha: 0.7,
                    shadowRadius: 4, shadowOpacity: 0.5, spinTurns: -0.85,
                    dash: [5, 7, 2, 7] as [NSNumber]),
        ]

        for spec in specs {
            let host = CALayer()
            let w = rx * 2 * spec.sx
            let h = ry * 2 * spec.sy
            host.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            host.position = center
            host.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            host.opacity = 0
            overlay.addSublayer(host)

            let rim = CAShapeLayer()
            rim.bounds = host.bounds
            rim.position = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
            rim.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            rim.path = CGPath(ellipseIn: rim.bounds.insetBy(dx: spec.lineWidth, dy: spec.lineWidth), transform: nil)
            rim.fillColor = nil
            rim.strokeColor = spec.color.withAlphaComponent(spec.alpha).cgColor
            rim.lineWidth = spec.lineWidth
            rim.lineCap = .round
            rim.lineJoin = .round
            if let dash = spec.dash {
                rim.lineDashPattern = dash
            }
            rim.shadowColor = Self.goldSoft.cgColor
            rim.shadowRadius = spec.shadowRadius
            rim.shadowOpacity = spec.shadowOpacity
            rim.shadowOffset = .zero
            host.addSublayer(rim)

            // Form: stroke draws on, then holds, then fades
            rim.strokeEnd = 0
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = vanish ? 0 : 1
            draw.toValue = 1
            draw.beginTime = t0
            draw.duration = duration * (vanish ? 0.28 : 0.2)
            draw.timingFunction = Self.easeOutSoft
            draw.fillMode = .both
            draw.isRemovedOnCompletion = false
            rim.add(draw, forKey: "draw")
            rim.strokeEnd = 1

            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = t0
            appear.duration = duration * 0.18
            appear.fillMode = .both
            appear.isRemovedOnCompletion = false
            host.add(appear, forKey: "in")

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.beginTime = t0 + duration * 0.72
            fade.duration = duration * 0.28
            fade.timingFunction = Self.easeInSoft
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            host.add(fade, forKey: "out")
            host.opacity = 0

            // Spin on the stroke layer; breath scale on the host — no transform clash
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = spinDir * spec.spinTurns * CGFloat.pi
            spin.beginTime = t0
            spin.duration = duration
            spin.timingFunction = Self.easeInOut
            spin.fillMode = .both
            spin.isRemovedOnCompletion = false
            rim.add(spin, forKey: "spin")

            let breath = CAKeyframeAnimation(keyPath: "transform.scale")
            if vanish {
                breath.values = [0.55, 1.04, 1.0, 0.96]
                breath.keyTimes = [0, 0.28, 0.55, 1]
            } else {
                breath.values = [0.5, 1.06, 1.0, 1.0]
                breath.keyTimes = [0, 0.32, 0.6, 1]
            }
            breath.duration = duration
            breath.beginTime = t0
            breath.fillMode = .both
            breath.isRemovedOnCompletion = false
            host.add(breath, forKey: "breath")
        }

        // Tiny tick marks around the mid rim (ornament, not noise)
        let tickHost = CALayer()
        let tw = rx * 2.12
        let th = ry * 2.12
        tickHost.bounds = CGRect(x: 0, y: 0, width: tw, height: th)
        tickHost.position = center
        tickHost.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        tickHost.opacity = 0
        overlay.addSublayer(tickHost)

        let ticks = CAShapeLayer()
        ticks.bounds = tickHost.bounds
        ticks.position = CGPoint(x: tickHost.bounds.midX, y: tickHost.bounds.midY)
        ticks.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let tickPath = CGMutablePath()
        let tickCount = 16
        for i in 0..<tickCount {
            let a = CGFloat(i) / CGFloat(tickCount) * .pi * 2
            let cosA = cos(a)
            let sinA = sin(a)
            let x0 = tw / 2 + cosA * (rx * 0.98)
            let y0 = th / 2 + sinA * (ry * 0.98)
            let x1 = tw / 2 + cosA * (rx * 1.08)
            let y1 = th / 2 + sinA * (ry * 1.08)
            tickPath.move(to: CGPoint(x: x0, y: y0))
            tickPath.addLine(to: CGPoint(x: x1, y: y1))
        }
        ticks.path = tickPath
        ticks.strokeColor = Self.goldSoft.withAlphaComponent(0.75).cgColor
        ticks.fillColor = nil
        ticks.lineWidth = 1.2
        ticks.lineCap = .round
        ticks.shadowColor = Self.gold.cgColor
        ticks.shadowRadius = 4
        ticks.shadowOpacity = 0.7
        ticks.shadowOffset = .zero
        tickHost.addSublayer(ticks)

        let tickIn = CABasicAnimation(keyPath: "opacity")
        tickIn.fromValue = 0
        tickIn.toValue = 1
        tickIn.beginTime = t0 + duration * 0.08
        tickIn.duration = duration * 0.2
        tickIn.fillMode = .both
        tickIn.isRemovedOnCompletion = false
        tickHost.add(tickIn, forKey: "in")

        let tickOut = CABasicAnimation(keyPath: "opacity")
        tickOut.fromValue = 1
        tickOut.toValue = 0
        tickOut.beginTime = t0 + duration * 0.7
        tickOut.duration = duration * 0.3
        tickOut.fillMode = .both
        tickOut.isRemovedOnCompletion = false
        tickHost.add(tickOut, forKey: "out")
        tickHost.opacity = 0

        let tickSpin = CABasicAnimation(keyPath: "transform.rotation.z")
        tickSpin.fromValue = 0
        tickSpin.toValue = spinDir * 0.9 * CGFloat.pi
        tickSpin.beginTime = t0
        tickSpin.duration = duration
        tickSpin.timingFunction = Self.easeInOut
        ticks.add(tickSpin, forKey: "spin")

        let tickBreath = CAKeyframeAnimation(keyPath: "transform.scale")
        tickBreath.values = vanish ? [0.55, 1.03, 0.97] : [0.5, 1.05, 1.0]
        tickBreath.keyTimes = [0, 0.35, 1]
        tickBreath.duration = duration
        tickBreath.beginTime = t0
        tickHost.add(tickBreath, forKey: "breath")
    }

    // MARK: - Genie (Dock-like)

    private func genie(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.72
        setEffectPadding?(32)
        afterPadding(onPet) { [weak self] in
            self?.runGenie(vanish: vanish, onPet: onPet, duration: duration, completion: completion)
        }
    }

    private func runGenie(vanish: Bool, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        guard let snap = snapshot(onPet) else {
            finish(after: 0.05, onPet: onPet, completion: completion)
            return
        }
        hideLivePet(onPet)

        let focus = CGPoint(x: rect.midX, y: rect.minY + 2)
        let strips = 40
        let stripH = rect.height / CGFloat(strips)
        let container = CALayer()
        container.frame = onPet.bounds
        overlay.addSublayer(container)
        stagingLayer = container

        for i in 0..<strips {
            let layer = CALayer()
            let y = rect.minY + CGFloat(i) * stripH
            layer.frame = CGRect(x: rect.minX, y: y, width: rect.width, height: ceil(stripH) + 0.5)
            layer.contents = snap.1
            // Flip contentsRect: CA uses bottom-left unit space for images from AppKit cache
            layer.contentsRect = CGRect(
                x: 0,
                y: CGFloat(i) / CGFloat(strips),
                width: 1,
                height: 1 / CGFloat(strips)
            )
            layer.contentsGravity = .resize
            layer.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer.position = CGPoint(x: rect.midX, y: y)
            layer.masksToBounds = true
            container.addSublayer(layer)

            // Cascade from top when vanishing (Dock genie)
            let t = CGFloat(i) / CGFloat(max(strips - 1, 1))
            let delay = CFTimeInterval(vanish ? (1 - t) : t) * duration * 0.38
            let move = CABasicAnimation(keyPath: "position")
            let scaleX = CABasicAnimation(keyPath: "transform.scale.x")
            let scaleY = CABasicAnimation(keyPath: "transform.scale.y")
            let fade = CABasicAnimation(keyPath: "opacity")

            // Width tapers toward focus for a true genie funnel
            let taper: CGFloat = 0.04 + t * 0.02

            if vanish {
                move.fromValue = layer.position
                move.toValue = focus
                scaleX.fromValue = 1
                scaleX.toValue = taper
                scaleY.fromValue = 1
                scaleY.toValue = 0.03
                fade.fromValue = 1
                fade.toValue = 0
                layer.position = focus
                layer.transform = CATransform3DMakeScale(taper, 0.03, 1)
                layer.opacity = 0
            } else {
                layer.position = focus
                layer.transform = CATransform3DMakeScale(taper, 0.03, 1)
                layer.opacity = 0
                move.fromValue = focus
                move.toValue = CGPoint(x: rect.midX, y: y)
                scaleX.fromValue = taper
                scaleX.toValue = 1
                scaleY.fromValue = 0.03
                scaleY.toValue = 1
                fade.fromValue = 0
                fade.toValue = 1
                layer.position = CGPoint(x: rect.midX, y: y)
                layer.transform = CATransform3DIdentity
                layer.opacity = 1
            }

            let timing = vanish ? Self.easeInSoft : Self.easeOutSoft
            for anim in [move, scaleX, scaleY, fade] as [CAAnimation] {
                anim.beginTime = CACurrentMediaTime() + delay
                anim.duration = duration * 0.62
                if let ba = anim as? CABasicAnimation {
                    ba.timingFunction = timing
                    ba.fillMode = .both
                    ba.isRemovedOnCompletion = false
                }
            }
            layer.add(move, forKey: "m")
            layer.add(scaleX, forKey: "sx")
            layer.add(scaleY, forKey: "sy")
            layer.add(fade, forKey: "f")
        }

        // Soft warm focal glow (not neon)
        let glow = CALayer()
        glow.contents = Self.softGlow
        glow.frame = CGRect(x: focus.x - 28, y: focus.y - 10, width: 56, height: 28)
        glow.opacity = 0
        overlay.addSublayer(glow)
        let glowTint = CALayer()
        glowTint.frame = glow.frame
        glowTint.backgroundColor = Self.goldSoft.withAlphaComponent(0.25).cgColor
        glowTint.cornerRadius = 14
        glowTint.opacity = 0
        overlay.addSublayer(glowTint)
        let glowPulse = CAKeyframeAnimation(keyPath: "opacity")
        glowPulse.values = [0, 0.7, 0]
        glowPulse.keyTimes = [0, 0.45, 1]
        glowPulse.duration = duration
        glow.add(glowPulse, forKey: "g")
        glowTint.add(glowPulse, forKey: "g")

        finish(after: duration, onPet: onPet, completion: completion)
    }

    // MARK: - Ash dissolve

    private func thanosAsh(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.88
        setEffectPadding?(40)
        afterPadding(onPet) { [weak self] in
            self?.runThanosAsh(vanish: vanish, onPet: onPet, duration: duration, completion: completion)
        }
    }

    private func runThanosAsh(vanish: Bool, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        guard let snap = snapshot(onPet) else {
            finish(after: 0.05, onPet: onPet, completion: completion)
            return
        }
        hideLivePet(onPet)

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snap.1
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer

        // Soft-edged dissolve (wide soft band, not a hard wipe)
        let mask = CAGradientLayer()
        mask.frame = petLayer.bounds.insetBy(dx: -2, dy: -2)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        // Soft band: clear → soft → solid across ~25% of width
        let softColors: [CGColor] = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.35).cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor
        ]

        if vanish {
            mask.colors = softColors
            mask.locations = [0, 0, 0.05, 0.22, 1] as [NSNumber]
        } else {
            mask.colors = softColors
            mask.locations = [0, 0.78, 0.95, 1, 1] as [NSNumber]
        }
        petLayer.mask = mask

        let locAnim = CABasicAnimation(keyPath: "locations")
        if vanish {
            locAnim.fromValue = [0, 0, 0.05, 0.22, 1]
            locAnim.toValue = [0, 0.78, 0.95, 1, 1]
        } else {
            locAnim.fromValue = [0, 0.78, 0.95, 1, 1]
            locAnim.toValue = [0, 0, 0.05, 0.22, 1]
        }
        locAnim.duration = duration * 0.9
        locAnim.timingFunction = Self.easeInOut
        locAnim.fillMode = .forwards
        locAnim.isRemovedOnCompletion = false
        mask.add(locAnim, forKey: "wipe")
        mask.locations = (vanish ? [0, 0.78, 0.95, 1, 1] : [0, 0, 0.05, 0.22, 1]) as [NSNumber]

        // Dust emits from a thin vertical front that travels with the wipe
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .line
        emitter.emitterMode = .outline
        emitter.emitterSize = CGSize(width: 0, height: rect.height * 0.88)
        emitter.renderMode = .oldestLast
        let startX = vanish ? rect.minX + 4 : rect.maxX - 4
        let endX = vanish ? rect.maxX - 4 : rect.minX + 4
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
        flake.xAcceleration = vanish ? 12 : -8
        flake.emissionLongitude = vanish ? (.pi * 0.15) : (.pi * 0.85)
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
        dust.emissionRange = .pi * 0.7
        dust.scale = 0.12
        dust.alphaSpeed = -1.4
        dust.color = Self.ashCool.cgColor

        emitter.emitterCells = [flake, dust]

        let stop = DispatchWorkItem { emitter.birthRate = 0 }
        particleStopWorkItem = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.72, execute: stop)

        finish(after: duration, onPet: onPet, completion: completion)
    }

    // MARK: - Light beam

    private func lightBeam(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.7
        setEffectPadding?(48)
        afterPadding(onPet) { [weak self] in
            self?.runLightBeam(vanish: vanish, onPet: onPet, duration: duration, completion: completion)
        }
    }

    private func runLightBeam(vanish: Bool, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        guard let snap = snapshot(onPet) else {
            finish(after: 0.05, onPet: onPet, completion: completion)
            return
        }
        hideLivePet(onPet)

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snap.1
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer

        // Vertical soft shaft
        let shaft = CAGradientLayer()
        let shaftW = max(28, rect.width * 0.55)
        shaft.frame = CGRect(
            x: rect.midX - shaftW / 2,
            y: rect.minY - 20,
            width: shaftW,
            height: rect.height + 40
        )
        shaft.colors = [
            Self.beamCore.withAlphaComponent(0).cgColor,
            Self.beamCore.withAlphaComponent(0.55).cgColor,
            Self.beamHalo.withAlphaComponent(0.25).cgColor,
            Self.beamCore.withAlphaComponent(0).cgColor
        ]
        shaft.locations = [0, 0.35, 0.65, 1]
        shaft.startPoint = CGPoint(x: 0.5, y: 0)
        shaft.endPoint = CGPoint(x: 0.5, y: 1)
        shaft.opacity = 0
        overlay.insertSublayer(shaft, below: petLayer)

        let halo = CALayer()
        halo.contents = Self.softGlow
        halo.frame = CGRect(x: rect.midX - rect.width * 0.7, y: rect.midY - rect.height * 0.55, width: rect.width * 1.4, height: rect.height * 1.1)
        halo.opacity = 0
        overlay.insertSublayer(halo, below: shaft)

        let lightPulse = CAKeyframeAnimation(keyPath: "opacity")
        lightPulse.values = [0, 0.85, 0.7, 0]
        lightPulse.keyTimes = [0, 0.2, 0.65, 1]
        lightPulse.duration = duration
        shaft.add(lightPulse, forKey: "o")
        let haloPulse = CAKeyframeAnimation(keyPath: "opacity")
        haloPulse.values = [0, 0.45, 0.3, 0]
        haloPulse.keyTimes = [0, 0.25, 0.6, 1]
        haloPulse.duration = duration
        halo.add(haloPulse, forKey: "o")

        // Pet dematerializes as vertical soft bands
        let mask = CAGradientLayer()
        mask.frame = petLayer.bounds
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.colors = [
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor,
            NSColor.clear.cgColor
        ]
        if vanish {
            mask.locations = [0, 1, 1, 1] as [NSNumber]
        } else {
            mask.locations = [0, 0, 0, 1] as [NSNumber]
        }
        petLayer.mask = mask

        let wipe = CABasicAnimation(keyPath: "locations")
        if vanish {
            wipe.fromValue = [0, 1, 1, 1]
            wipe.toValue = [0, 0, 0.15, 1]
        } else {
            wipe.fromValue = [0, 0, 0.15, 1]
            wipe.toValue = [0, 1, 1, 1]
        }
        wipe.duration = duration * 0.75
        wipe.beginTime = CACurrentMediaTime() + duration * 0.1
        wipe.timingFunction = Self.easeInOut
        wipe.fillMode = .forwards
        wipe.isRemovedOnCompletion = false
        mask.add(wipe, forKey: "wipe")
        mask.locations = (vanish ? [0, 0, 0.15, 1] : [0, 1, 1, 1]) as [NSNumber]

        // Slight brightness punch on pet
        let bright = CABasicAnimation(keyPath: "opacity")
        bright.fromValue = vanish ? 1 : 0.2
        bright.toValue = vanish ? 0 : 1
        bright.duration = duration * 0.7
        bright.beginTime = CACurrentMediaTime() + duration * 0.12
        bright.timingFunction = Self.easeInOut
        bright.fillMode = .forwards
        bright.isRemovedOnCompletion = false
        petLayer.add(bright, forKey: "op")
        petLayer.opacity = vanish ? 0 : 1

        // Few rising motes
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: rect.midX, y: vanish ? rect.minY : rect.maxY)
        emitter.emitterShape = .line
        emitter.emitterSize = CGSize(width: shaftW * 0.7, height: 1)
        emitter.renderMode = .additive
        let mote = CAEmitterCell()
        mote.contents = Self.softSpark
        mote.birthRate = 55
        mote.lifetime = 0.7
        mote.velocity = vanish ? 55 : -55
        mote.velocityRange = 20
        mote.scale = 0.14
        mote.alphaSpeed = -1.3
        mote.color = Self.beamCore.cgColor
        emitter.emitterCells = [mote]
        overlay.addSublayer(emitter)

        let stop = DispatchWorkItem { emitter.birthRate = 0 }
        particleStopWorkItem = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.55, execute: stop)

        finish(after: duration, onPet: onPet, completion: completion)
    }

    // MARK: - Blink

    private func flashBlink(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.38
        setEffectPadding?(24)
        afterPadding(onPet) { [weak self] in
            self?.runFlashBlink(vanish: vanish, onPet: onPet, duration: duration, completion: completion)
        }
    }

    private func runFlashBlink(vanish: Bool, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        guard let snap = snapshot(onPet) else {
            finish(after: 0.05, onPet: onPet, completion: completion)
            return
        }
        hideLivePet(onPet)

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snap.1
        petLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        petLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer

        // Soft camera flash
        let flash = CALayer()
        flash.contents = Self.softGlow
        flash.frame = rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25)
        flash.opacity = 0
        overlay.addSublayer(flash)

        let flashAnim = CAKeyframeAnimation(keyPath: "opacity")
        flashAnim.values = vanish ? [0, 0.85, 0] : [0, 0.7, 0]
        flashAnim.keyTimes = [0, 0.35, 1]
        flashAnim.duration = duration
        flash.add(flashAnim, forKey: "f")

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = vanish ? 1.0 : 1.12
        scale.toValue = vanish ? 0.88 : 1.0
        scale.duration = duration
        scale.timingFunction = vanish ? Self.easeInSoft : Self.easeOutSoft
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        petLayer.add(scale, forKey: "s")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = vanish ? 1 : 0
        fade.toValue = vanish ? 0 : 1
        fade.duration = duration * 0.85
        fade.timingFunction = Self.easeInOut
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        petLayer.add(fade, forKey: "o")
        petLayer.opacity = vanish ? 0 : 1
        petLayer.transform = CATransform3DMakeScale(vanish ? 0.88 : 1.0, vanish ? 0.88 : 1.0, 1)

        finish(after: duration, onPet: onPet, completion: completion)
    }

    // MARK: - Mist

    private func softMist(vanish: Bool, onPet: NSView, completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.75
        setEffectPadding?(44)
        afterPadding(onPet) { [weak self] in
            self?.runSoftMist(vanish: vanish, onPet: onPet, duration: duration, completion: completion)
        }
    }

    private func runSoftMist(vanish: Bool, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let rect = petRect(in: onPet)
        guard let snap = snapshot(onPet) else {
            finish(after: 0.05, onPet: onPet, completion: completion)
            return
        }
        hideLivePet(onPet)

        let petLayer = CALayer()
        petLayer.frame = rect
        petLayer.contents = snap.1
        overlay.addSublayer(petLayer)
        stagingLayer = petLayer

        // Layered soft mist blobs
        for i in 0..<4 {
            let cloud = CALayer()
            cloud.contents = Self.softGlow
            let grow = 1.0 + CGFloat(i) * 0.22
            let w = rect.width * grow * 1.15
            let h = rect.height * grow * 0.95
            cloud.frame = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
            cloud.opacity = 0
            overlay.addSublayer(cloud)

            let tint = CALayer()
            tint.frame = cloud.frame
            tint.backgroundColor = Self.mistTint.withAlphaComponent(0.12 + CGFloat(i) * 0.04).cgColor
            tint.cornerRadius = min(w, h) * 0.45
            tint.opacity = 0
            overlay.insertSublayer(tint, below: cloud)

            let delay = CFTimeInterval(i) * 0.05
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = vanish ? [0, 0.55, 0.7, 0] : [0, 0.65, 0.4, 0]
            o.keyTimes = [0, 0.3, 0.6, 1]
            o.duration = duration
            o.beginTime = CACurrentMediaTime() + delay
            o.fillMode = .both
            o.isRemovedOnCompletion = false

            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = vanish ? 0.55 : 1.25
            s.toValue = vanish ? 1.35 : 0.7
            s.duration = duration
            s.beginTime = CACurrentMediaTime() + delay
            s.timingFunction = Self.easeOutSoft
            s.fillMode = .both
            s.isRemovedOnCompletion = false

            cloud.add(o, forKey: "o")
            cloud.add(s, forKey: "s")
            tint.add(o, forKey: "o")
            tint.add(s, forKey: "s")
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = vanish ? 1 : 0
        fade.toValue = vanish ? 0 : 1
        fade.duration = duration * 0.7
        fade.beginTime = CACurrentMediaTime() + (vanish ? duration * 0.15 : duration * 0.2)
        fade.timingFunction = Self.easeInOut
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        petLayer.add(fade, forKey: "o")
        petLayer.opacity = vanish ? 0 : 1

        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = vanish ? 0 : 8
        drift.toValue = vanish ? 10 : 0
        drift.duration = duration
        drift.timingFunction = Self.easeInOut
        petLayer.add(drift, forKey: "drift")

        finish(after: duration, onPet: onPet, completion: completion)
    }
}
