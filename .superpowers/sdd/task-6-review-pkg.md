# Task 6 review package (post-fix)
```swift
import AppKit
import DesktopPetCore

final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class TeleportEffectRenderer {
    private weak var host: NSView?
    private let overlay = CALayer()
    private var completionWorkItem: DispatchWorkItem?
    private var bubbleDismissWorkItem: DispatchWorkItem?
    private var particleBirthRateWorkItem: DispatchWorkItem?
    private var bubbleView: NSTextField?

    private static let cyan = NSColor(calibratedRed: 0.35, green: 0.85, blue: 1, alpha: 1)
    private static let violet = NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.95, alpha: 1)

    init(host: NSView) {
        self.host = host
        host.wantsLayer = true
        overlay.name = "teleportOverlay"
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.layer?.addSublayer(overlay)
    }

    func cancel() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        bubbleDismissWorkItem?.cancel()
        bubbleDismissWorkItem = nil
        particleBirthRateWorkItem?.cancel()
        particleBirthRateWorkItem = nil
        clearOverlay()
        if let host {
            resetPetView(host)
            host.layer?.removeAllAnimations()
        }
        dismissBubble()
    }

    func playVanish(
        style: TeleportEffectStyle,
        onPet: NSView,
        completion: @escaping () -> Void
    ) {
        prepareForNewEffect(onPet: onPet, resetPetPresentation: true)
        let duration = Self.duration(for: style)
        switch style {
        case .portal:
            animatePortal(vanish: true, onPet: onPet, duration: duration, completion: completion)
        case .particles:
            animateParticles(vanish: true, onPet: onPet, duration: duration, completion: completion)
        case .warp:
            animateWarp(vanish: true, onPet: onPet, duration: duration, completion: completion)
        }
    }

    func playAppear(
        style: TeleportEffectStyle,
        onPet: NSView,
        completion: @escaping () -> Void
    ) {
        prepareForNewEffect(onPet: onPet, resetPetPresentation: false)
        let duration = Self.duration(for: style)
        switch style {
        case .portal:
            animatePortal(vanish: false, onPet: onPet, duration: duration, completion: completion)
        case .particles:
            animateParticles(vanish: false, onPet: onPet, duration: duration, completion: completion)
        case .warp:
            animateWarp(vanish: false, onPet: onPet, duration: duration, completion: completion)
        }
    }

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
        frame.origin.x = (petView.bounds.width - frame.width) / 2
        frame.origin.y = petView.bounds.height + 6

        if let win = petView.window {
            let midY = win.frame.midY
            if let screen = win.screen, midY > screen.visibleFrame.midY {
                frame.origin.y = -frame.height - 6
            }
        }

        label.frame = frame
        label.alphaValue = 0
        petView.addSubview(label)
        bubbleView = label

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            label.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            self?.dismissBubble()
        }
        bubbleDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismissBubble() {
        bubbleDismissWorkItem?.cancel()
        bubbleDismissWorkItem = nil
        bubbleView?.removeFromSuperview()
        bubbleView = nil
    }

    // MARK: - Preparation

    private func prepareForNewEffect(onPet: NSView, resetPetPresentation: Bool) {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        particleBirthRateWorkItem?.cancel()
        particleBirthRateWorkItem = nil
        clearOverlay()
        onPet.layer?.removeAllAnimations()
        if resetPetPresentation {
            resetPetView(onPet)
        }
        ensureOverlay(on: onPet)
    }

    private func ensureOverlay(on pet: NSView) {
        pet.wantsLayer = true
        overlay.frame = pet.bounds
        if overlay.superlayer !== pet.layer {
            pet.layer?.addSublayer(overlay)
        }
    }

    private func clearOverlay() {
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        overlay.removeAllAnimations()
    }

    private func resetPetView(_ pet: NSView) {
        pet.alphaValue = 1
        pet.layer?.opacity = 1
        pet.layer?.transform = CATransform3DIdentity
    }

    private func finishAfter(_ duration: CFTimeInterval, completion: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            self?.clearOverlay()
            completion()
        }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func duration(for style: TeleportEffectStyle) -> CFTimeInterval {
        switch style {
        case .portal: 0.65
        case .particles: 0.75
        case .warp: 0.55
        }
    }

    // MARK: - Portal

    private func animatePortal(
        vanish: Bool,
        onPet: NSView,
        duration: CFTimeInterval,
        completion: @escaping () -> Void
    ) {
        let bounds = onPet.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.height * 0.38)
        let baseRadius = min(bounds.width, bounds.height) * 0.22

        let ring = CAShapeLayer()
        ring.path = CGPath(
            ellipseIn: CGRect(
                x: center.x - baseRadius,
                y: center.y - baseRadius,
                width: baseRadius * 2,
                height: baseRadius * 2
            ),
            transform: nil
        )
        ring.fillColor = nil
        ring.strokeColor = Self.cyan.cgColor
        ring.lineWidth = 2.5
        ring.shadowColor = Self.violet.cgColor
        ring.shadowRadius = 10
        ring.shadowOpacity = 0.85
        ring.shadowOffset = .zero
        ring.position = .zero
        ring.bounds = bounds
        overlay.addSublayer(ring)

        onPet.wantsLayer = true
        let petLayer = onPet.layer!

        if vanish {
            petLayer.opacity = 1
            petLayer.transform = CATransform3DIdentity

            let ringScale = CABasicAnimation(keyPath: "transform.scale")
            ringScale.fromValue = 0.2
            ringScale.toValue = 1.2
            ringScale.duration = duration * 0.55
            ringScale.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let ringFade = CABasicAnimation(keyPath: "opacity")
            ringFade.fromValue = 1
            ringFade.toValue = 0
            ringFade.beginTime = duration * 0.45
            ringFade.duration = duration * 0.55
            ringFade.fillMode = .forwards
            ringFade.isRemovedOnCompletion = false

            let petOpacity = CABasicAnimation(keyPath: "opacity")
            petOpacity.fromValue = 1
            petOpacity.toValue = 0
            petOpacity.duration = duration
            petOpacity.fillMode = .forwards
            petOpacity.isRemovedOnCompletion = false

            let petScale = CABasicAnimation(keyPath: "transform.scale")
            petScale.fromValue = 1
            petScale.toValue = 0.88
            petScale.duration = duration
            petScale.fillMode = .forwards
            petScale.isRemovedOnCompletion = false

            ring.add(ringScale, forKey: "portalRingScale")
            ring.add(ringFade, forKey: "portalRingFade")
            petLayer.add(petOpacity, forKey: "portalPetOpacity")
            petLayer.add(petScale, forKey: "portalPetScale")

            petLayer.opacity = 0
            petLayer.transform = CATransform3DScale(CATransform3DIdentity, 0.88, 0.88, 1)
        } else {
            petLayer.opacity = 0
            petLayer.transform = CATransform3DScale(CATransform3DIdentity, 0.88, 0.88, 1)
            ring.opacity = 0
            ring.transform = CATransform3DScale(CATransform3DIdentity, 0.2, 0.2, 1)

            let ringOpen = CABasicAnimation(keyPath: "transform.scale")
            ringOpen.fromValue = 0.2
            ringOpen.toValue = 1.2
            ringOpen.duration = duration * 0.5
            ringOpen.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let ringClose = CABasicAnimation(keyPath: "opacity")
            ringClose.fromValue = 1
            ringClose.toValue = 0
            ringClose.beginTime = duration * 0.5
            ringClose.duration = duration * 0.5
            ringClose.fillMode = .forwards
            ringClose.isRemovedOnCompletion = false

            let petOpacity = CABasicAnimation(keyPath: "opacity")
            petOpacity.fromValue = 0
            petOpacity.toValue = 1
            petOpacity.duration = duration * 0.85
            petOpacity.fillMode = .forwards
            petOpacity.isRemovedOnCompletion = false

            let petScale = CABasicAnimation(keyPath: "transform.scale")
            petScale.fromValue = 0.88
            petScale.toValue = 1
            petScale.duration = duration * 0.85
            petScale.fillMode = .forwards
            petScale.isRemovedOnCompletion = false

            ring.opacity = 1
            ring.add(ringOpen, forKey: "portalRingOpen")
            ring.add(ringClose, forKey: "portalRingClose")
            petLayer.add(petOpacity, forKey: "portalPetOpacity")
            petLayer.add(petScale, forKey: "portalPetScale")

            petLayer.opacity = 1
            petLayer.transform = CATransform3DIdentity
            onPet.alphaValue = 1
        }

        finishAfter(duration, completion: completion)
    }

    // MARK: - Particles

    private func animateParticles(
        vanish: Bool,
        onPet: NSView,
        duration: CFTimeInterval,
        completion: @escaping () -> Void
    ) {
        let bounds = onPet.bounds
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitter.emitterShape = .rectangle
        emitter.emitterSize = CGSize(width: bounds.width * 0.6, height: bounds.height * 0.6)
        emitter.renderMode = .additive

        let cell = CAEmitterCell()
        cell.contents = Self.particleImage().cgImage(forProposedRect: nil, context: nil, hints: nil)
        cell.birthRate = vanish ? 900 : 700
        cell.lifetime = Float(duration * 0.9)
        cell.velocity = vanish ? 140 : -120
        cell.velocityRange = 60
        cell.emissionRange = .pi * 2
        cell.scale = 0.35
        cell.scaleRange = 0.2
        cell.alphaSpeed = vanish ? -1.2 : -0.8
        cell.color = Self.cyan.cgColor
        cell.redRange = 0.1
        cell.blueRange = 0.15
        cell.greenRange = 0.05
        emitter.emitterCells = [cell]
        overlay.addSublayer(emitter)

        onPet.wantsLayer = true
        let petLayer = onPet.layer!

        let petOpacity = CABasicAnimation(keyPath: "opacity")
        petOpacity.fromValue = vanish ? 1 : 0
        petOpacity.toValue = vanish ? 0 : 1
        petOpacity.duration = duration * 0.85
        petOpacity.fillMode = .forwards
        petOpacity.isRemovedOnCompletion = false
        petLayer.add(petOpacity, forKey: "particlesPetOpacity")
        petLayer.opacity = vanish ? 0 : 1
        if !vanish {
            onPet.alphaValue = 1
        }

        let birthRateStop = DispatchWorkItem {
            cell.birthRate = 0
        }
        particleBirthRateWorkItem = birthRateStop
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.35, execute: birthRateStop)

        finishAfter(duration, completion: completion)
    }

    // MARK: - Warp

    private func animateWarp(
        vanish: Bool,
        onPet: NSView,
        duration: CFTimeInterval,
        completion: @escaping () -> Void
    ) {
        let bounds = onPet.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let baseRadius = min(bounds.width, bounds.height) * 0.12

        for index in 0..<3 {
            let ripple = CAShapeLayer()
            let radius = baseRadius + CGFloat(index) * baseRadius * 0.35
            ripple.path = CGPath(
                ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
            ripple.fillColor = nil
            ripple.strokeColor = Self.cyan.withAlphaComponent(0.85 - CGFloat(index) * 0.15).cgColor
            ripple.lineWidth = 2
            ripple.shadowColor = Self.violet.cgColor
            ripple.shadowRadius = 6
            ripple.shadowOpacity = 0.6
            ripple.position = .zero
            ripple.bounds = bounds
            overlay.addSublayer(ripple)

            let delay = CFTimeInterval(index) * duration * 0.12
            let rippleDuration = duration * 0.75

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = vanish ? 0.6 : 0.3
            scale.toValue = vanish ? 2.2 : 1.8
            scale.beginTime = delay
            scale.duration = rippleDuration
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            fade.beginTime = delay
            fade.duration = rippleDuration
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false

            ripple.add(scale, forKey: "warpScale\(index)")
            ripple.add(fade, forKey: "warpFade\(index)")
            ripple.opacity = 0
        }

        onPet.wantsLayer = true
        let petLayer = onPet.layer!

        if vanish {
            petLayer.opacity = 1
            petLayer.transform = CATransform3DIdentity

            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 1.15, 1]
            pulse.keyTimes = [0, 0.35, 0.55]
            pulse.duration = duration * 0.55
            pulse.fillMode = .forwards
            pulse.isRemovedOnCompletion = false

            let petFade = CABasicAnimation(keyPath: "opacity")
            petFade.fromValue = 1
            petFade.toValue = 0
            petFade.beginTime = duration * 0.3
            petFade.duration = duration * 0.7
            petFade.fillMode = .forwards
            petFade.isRemovedOnCompletion = false

            petLayer.add(pulse, forKey: "warpPulse")
            petLayer.add(petFade, forKey: "warpPetFade")
            petLayer.opacity = 0
        } else {
            petLayer.opacity = 0
            petLayer.transform = CATransform3DScale(CATransform3DIdentity, 0.7, 0.7, 1)

            let petOpacity = CABasicAnimation(keyPath: "opacity")
            petOpacity.fromValue = 0
            petOpacity.toValue = 1
            petOpacity.duration = duration * 0.8
            petOpacity.fillMode = .forwards
            petOpacity.isRemovedOnCompletion = false

            let petScale = CABasicAnimation(keyPath: "transform.scale")
            petScale.fromValue = 0.7
            petScale.toValue = 1
            petScale.duration = duration * 0.8
            petScale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            petScale.fillMode = .forwards
            petScale.isRemovedOnCompletion = false

            petLayer.add(petOpacity, forKey: "warpPetOpacity")
            petLayer.add(petScale, forKey: "warpPetScale")
            petLayer.opacity = 1
            petLayer.transform = CATransform3DIdentity
            onPet.alphaValue = 1
        }

        finishAfter(duration, completion: completion)
    }

    // MARK: - Assets

    private static func particleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        cyan.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }
}
```
