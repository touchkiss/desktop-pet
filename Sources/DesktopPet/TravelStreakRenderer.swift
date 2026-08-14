import AppKit
import DesktopPetCore
import QuartzCore

/// Click-through transparent overlay window that flies a comet streak from
/// the vanish point to the landing point, visually bridging the two ends of
/// a teleport. The window spans the bounding box of the arc (may straddle
/// displays) and lives only for the duration of the flight plus a short
/// tail-fade, then closes itself.
@MainActor
final class TravelStreakRenderer {
    struct Palette {
        var core: NSColor
        var glow: NSColor
    }

    private var window: NSWindow?
    private var completionWork: DispatchWorkItem?
    private var sparkStopWork: DispatchWorkItem?
    private var teardownWork: DispatchWorkItem?

    static func palette(for style: TeleportEffectStyle) -> Palette {
        switch style {
        case .beam, .blink:
            return Palette(
                core: NSColor(calibratedRed: 0.85, green: 0.94, blue: 1.0, alpha: 1),
                glow: NSColor(calibratedRed: 0.55, green: 0.78, blue: 0.95, alpha: 1)
            )
        case .ink:
            // 水墨: paper-white core, diluted-ink wash glow.
            return Palette(
                core: NSColor(calibratedWhite: 0.97, alpha: 1),
                glow: NSColor(calibratedRed: 0.42, green: 0.47, blue: 0.52, alpha: 1)
            )
        default:
            return Palette(
                core: NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.68, alpha: 1),
                glow: NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.30, alpha: 1)
            )
        }
    }

    /// Fly the middle bridge. `from` / `to` are pet centers in global
    /// screen coordinates; `petSpan` scales impact/rider sizes; `rider` is
    /// the cat's snapshot (cloud passenger / hop silhouettes). `completion`
    /// fires at (or just before) arrival so the appear effect hands off
    /// seamlessly.
    func play(
        from: CGPoint,
        to: CGPoint,
        petSpan: CGFloat,
        style: TeleportEffectStyle,
        middle: TravelMiddle,
        rider: CGImage?,
        completion: @escaping () -> Void
    ) {
        switch middle {
        case .none, .comet:
            playComet(from: from, to: to, petSpan: petSpan, style: style, completion: completion)
        case .cloud:
            playCloud(from: from, to: to, petSpan: petSpan, rider: rider, completion: completion)
        case .vortex:
            playVortex(from: from, to: to, petSpan: petSpan, style: style, completion: completion)
        case .shadowHops:
            playHops(from: from, to: to, petSpan: petSpan, style: style, rider: rider, completion: completion)
        }
    }

    private func playComet(
        from: CGPoint,
        to: CGPoint,
        petSpan: CGFloat,
        style: TeleportEffectStyle,
        completion: @escaping () -> Void
    ) {
        cancel()

        let palette = Self.palette(for: style)

        // Winding route: 1–3 alternating-side turns instead of one arc.
        var randoms: [Double] = []
        for _ in 0..<12 { randoms.append(Double.random(in: 0...1)) }
        let waypoints = TeleportMath.travelWaypoints(from: from, to: to, unitRandoms: randoms)
        let pathLength = TeleportMath.travelPathLength(from: from, to: to, waypoints: waypoints)
        let duration = TeleportMath.travelDuration(distance: pathLength)

        let pad: CGFloat = 140
        var box = CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        ).insetBy(dx: -pad, dy: -pad)
        for waypoint in waypoints {
            box = box.union(CGRect(x: waypoint.x - pad, y: waypoint.y - pad, width: pad * 2, height: pad * 2))
        }

        let win = makeWindow(frame: box)
        window = win
        guard let root = win.contentView?.layer else {
            close()
            completion()
            return
        }

        func local(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - box.minX, y: p.y - box.minY)
        }
        let p0 = local(from)
        let p2 = local(to)
        let localWaypoints = waypoints.map(local)

        // Chord normal, used to braid the side strands around the main path.
        let chordLength = max(1, hypot(to.x - from.x, to.y - from.y))
        let normal = CGVector(
            dx: -(to.y - from.y) / chordLength,
            dy: (to.x - from.x) / chordLength
        )

        // Smooth polyline: each waypoint becomes a control point, the curve
        // glides through the segment midpoints.
        func smoothPath(through points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            guard let first = points.first, let last = points.last else { return path }
            path.move(to: first)
            if points.count <= 2 {
                path.addLine(to: last)
                return path
            }
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(
                    x: (points[i].x + points[i + 1].x) / 2,
                    y: (points[i].y + points[i + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: points[i])
            }
            path.addLine(to: last)
            return path
        }

        func braidedPoints(offset: CGFloat) -> [CGPoint] {
            var points = [p0]
            points += localWaypoints.map {
                CGPoint(x: $0.x + normal.dx * offset, y: $0.y + normal.dy * offset)
            }
            points.append(p2)
            return points
        }

        let path = smoothPath(through: braidedPoints(offset: 0))

        let now = CACurrentMediaTime()
        let flyTiming = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.42, 1)

        // —— Trail stroke: head draws it on, tail chases and consumes it ——
        let trail = CAShapeLayer()
        trail.path = path
        trail.fillColor = nil
        trail.strokeColor = palette.glow.withAlphaComponent(0.75).cgColor
        trail.lineWidth = 2.5
        trail.lineCap = .round
        trail.shadowColor = palette.glow.cgColor
        trail.shadowRadius = 6
        trail.shadowOpacity = 0.9
        trail.shadowOffset = .zero
        trail.strokeEnd = 0
        root.addSublayer(trail)

        let drawOn = CABasicAnimation(keyPath: "strokeEnd")
        drawOn.fromValue = 0
        drawOn.toValue = 1
        drawOn.beginTime = now
        drawOn.duration = duration
        drawOn.timingFunction = flyTiming
        drawOn.fillMode = .both
        drawOn.isRemovedOnCompletion = false
        trail.add(drawOn, forKey: "draw")
        trail.strokeEnd = 1

        let chase = CABasicAnimation(keyPath: "strokeStart")
        chase.fromValue = 0
        chase.toValue = 1
        chase.beginTime = now + duration * 0.3
        chase.duration = duration
        chase.timingFunction = flyTiming
        chase.fillMode = .both
        chase.isRemovedOnCompletion = false
        trail.add(chase, forKey: "chase")
        trail.strokeStart = 1

        // —— Side strands: thinner wisps braided around the main path,
        // slightly delayed so the streak reads as a bundle, not a wire ——
        for (index, offset) in [CGFloat(9), CGFloat(-8)].enumerated() {
            let strandPath = smoothPath(through: braidedPoints(offset: offset))
            let delay = 0.035 * CFTimeInterval(index + 1)

            let wisp = CAShapeLayer()
            wisp.path = strandPath
            wisp.fillColor = nil
            wisp.strokeColor = palette.glow.withAlphaComponent(0.45).cgColor
            wisp.lineWidth = 1.2
            wisp.lineCap = .round
            wisp.shadowColor = palette.glow.cgColor
            wisp.shadowRadius = 4
            wisp.shadowOpacity = 0.6
            wisp.shadowOffset = .zero
            wisp.strokeEnd = 0
            root.addSublayer(wisp)

            let wispDraw = CABasicAnimation(keyPath: "strokeEnd")
            wispDraw.fromValue = 0
            wispDraw.toValue = 1
            wispDraw.beginTime = now + delay
            wispDraw.duration = duration
            wispDraw.timingFunction = flyTiming
            wispDraw.fillMode = .both
            wispDraw.isRemovedOnCompletion = false
            wisp.add(wispDraw, forKey: "draw")
            wisp.strokeEnd = 1

            let wispChase = CABasicAnimation(keyPath: "strokeStart")
            wispChase.fromValue = 0
            wispChase.toValue = 1
            wispChase.beginTime = now + delay + duration * 0.3
            wispChase.duration = duration
            wispChase.timingFunction = flyTiming
            wispChase.fillMode = .both
            wispChase.isRemovedOnCompletion = false
            wisp.add(wispChase, forKey: "chase")
            wisp.strokeStart = 1

            let wispHead = CALayer()
            wispHead.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
            wispHead.contents = Self.makeRadial(size: 18, color: palette.core)
            wispHead.position = p0
            wispHead.opacity = 0
            root.addSublayer(wispHead)

            let wispFly = CAKeyframeAnimation(keyPath: "position")
            wispFly.path = strandPath
            wispFly.calculationMode = .paced
            wispFly.beginTime = now + delay
            wispFly.duration = duration
            wispFly.timingFunction = flyTiming
            wispFly.fillMode = .both
            wispFly.isRemovedOnCompletion = false
            wispHead.add(wispFly, forKey: "fly")
            wispHead.position = p2

            let wispFade = CAKeyframeAnimation(keyPath: "opacity")
            wispFade.values = [0, 0.8, 0.8, 0]
            wispFade.keyTimes = [0, 0.12, 0.86, 1]
            wispFade.beginTime = now + delay
            wispFade.duration = duration
            wispFade.fillMode = .both
            wispFade.isRemovedOnCompletion = false
            wispHead.add(wispFade, forKey: "o")
        }

        // —— Comet head with replicator afterimages ——
        let replicator = CAReplicatorLayer()
        replicator.frame = CGRect(origin: .zero, size: box.size)
        replicator.instanceCount = 6
        replicator.instanceDelay = 0.022
        replicator.instanceAlphaOffset = -0.16
        root.addSublayer(replicator)

        let head = CALayer()
        head.bounds = CGRect(x: 0, y: 0, width: 46, height: 46)
        head.contents = Self.makeRadial(size: 46, color: palette.glow)
        head.position = p0
        replicator.addSublayer(head)

        let core = CALayer()
        core.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        core.contents = Self.makeRadial(size: 18, color: palette.core)
        core.position = CGPoint(x: head.bounds.midX, y: head.bounds.midY)
        head.addSublayer(core)

        let fly = CAKeyframeAnimation(keyPath: "position")
        fly.path = path
        fly.calculationMode = .paced
        fly.beginTime = now
        fly.duration = duration
        fly.timingFunction = flyTiming
        fly.fillMode = .both
        fly.isRemovedOnCompletion = false
        head.add(fly, forKey: "fly")
        head.position = p2

        // Stay bright to the end, then SLAM into the point — a brief swell
        // and collapse instead of a passive fade-out mid-air.
        let headFade = CAKeyframeAnimation(keyPath: "opacity")
        headFade.values = [0, 1, 1, 0]
        headFade.keyTimes = [0, 0.1, 0.96, 1]
        headFade.beginTime = now
        headFade.duration = duration
        headFade.fillMode = .both
        headFade.isRemovedOnCompletion = false
        head.add(headFade, forKey: "o")
        head.opacity = 0

        let slam = CAKeyframeAnimation(keyPath: "transform.scale")
        slam.values = [1.0, 1.0, 1.3, 0.15]
        slam.keyTimes = [0, 0.82, 0.93, 1]
        slam.beginTime = now
        slam.duration = duration
        slam.fillMode = .both
        slam.isRemovedOnCompletion = false
        head.add(slam, forKey: "slam")

        // —— Micro sparks shed along the way ——
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = p0
        emitter.emitterShape = .point
        emitter.renderMode = .additive
        let spark = CAEmitterCell()
        spark.contents = Self.makeRadial(size: 12, color: .white)
        spark.color = palette.glow.cgColor
        spark.birthRate = 220
        spark.lifetime = 0.35
        spark.lifetimeRange = 0.15
        spark.velocity = 12
        spark.velocityRange = 18
        spark.emissionRange = .pi * 2
        spark.scale = 0.3
        spark.scaleRange = 0.15
        spark.scaleSpeed = -0.4
        spark.alphaSpeed = -2.6

        // Hot pinpoint flashes — brief, jittery.
        let flare = CAEmitterCell()
        flare.contents = Self.makeRadial(size: 10, color: .white)
        flare.color = palette.core.cgColor
        flare.birthRate = 90
        flare.lifetime = 0.22
        flare.lifetimeRange = 0.08
        flare.velocity = 26
        flare.velocityRange = 34
        flare.emissionRange = .pi * 2
        flare.scale = 0.14
        flare.scaleSpeed = -0.5
        flare.alphaSpeed = -3.5

        // Heavier motes that fall away from the path like cooling embers.
        let driftMote = CAEmitterCell()
        driftMote.contents = Self.makeRadial(size: 14, color: .white)
        driftMote.color = palette.glow.withAlphaComponent(0.9).cgColor
        driftMote.birthRate = 45
        driftMote.lifetime = 0.6
        driftMote.lifetimeRange = 0.2
        driftMote.velocity = 8
        driftMote.velocityRange = 12
        driftMote.yAcceleration = -70
        driftMote.emissionRange = .pi * 2
        driftMote.scale = 0.2
        driftMote.scaleRange = 0.1
        driftMote.alphaSpeed = -1.7

        emitter.emitterCells = [spark, flare, driftMote]
        root.addSublayer(emitter)

        let emitterMove = CAKeyframeAnimation(keyPath: "emitterPosition")
        emitterMove.path = path
        emitterMove.calculationMode = .paced
        emitterMove.beginTime = now
        emitterMove.duration = duration
        emitterMove.timingFunction = flyTiming
        emitterMove.fillMode = .both
        emitterMove.isRemovedOnCompletion = false
        emitter.add(emitterMove, forKey: "move")
        emitter.emitterPosition = p2

        // —— Impact at the landing point: fast core flash, expanding
        // shockwave rings, gravity-bound spark scatter and a lingering
        // afterglow — all scaled to the pet's size ——
        let impactR = min(110, max(36, petSpan * 0.42))
        let tArrive = max(0.05, duration - 0.05)
        let impactBegin = now + tArrive

        // Afterglow sits behind everything and outlives the flash.
        let afterglow = CALayer()
        afterglow.bounds = CGRect(x: 0, y: 0, width: impactR * 2.6, height: impactR * 2.6)
        afterglow.contents = Self.makeRadial(size: 64, color: palette.glow)
        afterglow.position = p2
        afterglow.opacity = 0
        root.insertSublayer(afterglow, at: 0)

        let glowPulse = CAKeyframeAnimation(keyPath: "opacity")
        glowPulse.values = [0, 0.5, 0]
        glowPulse.keyTimes = [0, 0.25, 1]
        glowPulse.beginTime = impactBegin
        glowPulse.duration = 0.6
        glowPulse.fillMode = .both
        glowPulse.isRemovedOnCompletion = false
        afterglow.add(glowPulse, forKey: "o")

        // Core flash: snaps to full brightness in a few frames, decays slow.
        let impactCore = CALayer()
        let impactCoreSide = impactR * 0.9
        impactCore.bounds = CGRect(x: 0, y: 0, width: impactCoreSide, height: impactCoreSide)
        impactCore.contents = Self.makeRadial(size: 48, color: palette.core)
        impactCore.position = p2
        impactCore.opacity = 0
        root.addSublayer(impactCore)

        let coreFlash = CAKeyframeAnimation(keyPath: "opacity")
        coreFlash.values = [0, 1, 0]
        coreFlash.keyTimes = [0, 0.16, 1]
        coreFlash.beginTime = impactBegin
        coreFlash.duration = 0.32
        coreFlash.fillMode = .both
        coreFlash.isRemovedOnCompletion = false
        impactCore.add(coreFlash, forKey: "flash")

        let coreScale = CABasicAnimation(keyPath: "transform.scale")
        coreScale.fromValue = 0.55
        coreScale.toValue = 1.05
        coreScale.beginTime = impactBegin
        coreScale.duration = 0.32
        coreScale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        coreScale.fillMode = .both
        coreScale.isRemovedOnCompletion = false
        impactCore.add(coreScale, forKey: "s")

        // Shockwave rings: expand while thinning and fading. Two of them,
        // offset in time and size — physical impact, not a flat blob.
        func addShockRing(delay: CFTimeInterval, scaleTo: CGFloat, lineWidth: CGFloat, peak: Double) {
            let ring = CAShapeLayer()
            ring.bounds = CGRect(x: 0, y: 0, width: impactR * 2, height: impactR * 2)
            ring.position = p2
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = palette.core.withAlphaComponent(0.9).cgColor
            ring.lineWidth = lineWidth
            ring.shadowColor = palette.glow.cgColor
            ring.shadowRadius = 8
            ring.shadowOpacity = 0.9
            ring.shadowOffset = .zero
            ring.opacity = 0
            root.addSublayer(ring)

            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.15
            grow.toValue = scaleTo
            grow.beginTime = impactBegin + delay
            grow.duration = 0.42
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            grow.fillMode = .both
            grow.isRemovedOnCompletion = false
            ring.add(grow, forKey: "grow")

            let thin = CABasicAnimation(keyPath: "lineWidth")
            thin.fromValue = lineWidth
            thin.toValue = lineWidth * 0.2
            thin.beginTime = impactBegin + delay
            thin.duration = 0.42
            thin.timingFunction = CAMediaTimingFunction(name: .easeOut)
            thin.fillMode = .both
            thin.isRemovedOnCompletion = false
            ring.add(thin, forKey: "thin")

            let ringFade = CAKeyframeAnimation(keyPath: "opacity")
            ringFade.values = [peak, peak * 0.7, 0]
            ringFade.keyTimes = [0, 0.35, 1]
            ringFade.beginTime = impactBegin + delay
            ringFade.duration = 0.42
            ringFade.fillMode = .both
            ringFade.isRemovedOnCompletion = false
            ring.add(ringFade, forKey: "o")
        }
        addShockRing(delay: 0, scaleTo: 1.0, lineWidth: 3, peak: 0.95)
        addShockRing(delay: 0.06, scaleTo: 1.4, lineWidth: 1.6, peak: 0.55)

        // Spark scatter: a one-shot burst thrown outwards, pulled down by
        // gravity as it dies — switched on exactly at arrival.
        let sparkBurst = CAEmitterLayer()
        sparkBurst.emitterPosition = p2
        sparkBurst.emitterShape = .point
        sparkBurst.renderMode = .additive
        sparkBurst.birthRate = 0
        let ember = CAEmitterCell()
        ember.contents = Self.makeRadial(size: 12, color: .white)
        ember.color = palette.core.cgColor
        ember.birthRate = 320
        ember.lifetime = 0.45
        ember.lifetimeRange = 0.15
        ember.velocity = 95
        ember.velocityRange = 55
        ember.emissionRange = .pi * 2
        ember.yAcceleration = -170
        ember.scale = 0.28
        ember.scaleRange = 0.12
        ember.scaleSpeed = -0.35
        ember.alphaSpeed = -2.2
        sparkBurst.emitterCells = [ember]
        root.addSublayer(sparkBurst)

        // Arrival: stop shedding along the path, fire the sparks, hand off
        // to the appear effect (slightly early, under the flash peak).
        let arrive = DispatchWorkItem { [weak emitter, weak sparkBurst] in
            emitter?.birthRate = 0
            sparkBurst?.birthRate = 1
            completion()
        }
        completionWork = arrive
        DispatchQueue.main.asyncAfter(deadline: .now() + tArrive, execute: arrive)

        let sparkStop = DispatchWorkItem { [weak sparkBurst] in
            sparkBurst?.birthRate = 0
        }
        sparkStopWork = sparkStop
        DispatchQueue.main.asyncAfter(deadline: .now() + tArrive + 0.08, execute: sparkStop)

        let teardown = DispatchWorkItem { [weak self] in
            self?.close()
        }
        teardownWork = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.8, execute: teardown)
    }

    // MARK: - 筋斗云 (cloud carrier)

    private func playCloud(
        from: CGPoint,
        to: CGPoint,
        petSpan: CGFloat,
        rider: CGImage?,
        completion: @escaping () -> Void
    ) {
        cancel()
        var randoms: [Double] = []
        for _ in 0..<12 { randoms.append(Double.random(in: 0...1)) }
        let waypoints = TeleportMath.travelWaypoints(from: from, to: to, unitRandoms: randoms)
        let pathLength = TeleportMath.travelPathLength(from: from, to: to, waypoints: waypoints)
        // The cloud is leisurely — it's a ride, not a bolt.
        let duration = min(1.05, max(0.5, pathLength / 1700))

        let pad: CGFloat = 150
        var box = CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        ).insetBy(dx: -pad, dy: -pad)
        for waypoint in waypoints {
            box = box.union(CGRect(x: waypoint.x - pad, y: waypoint.y - pad, width: pad * 2, height: pad * 2))
        }

        let win = makeWindow(frame: box)
        window = win
        guard let root = win.contentView?.layer else {
            close()
            completion()
            return
        }
        func local(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - box.minX, y: p.y - box.minY)
        }
        let p0 = local(from)
        let p2 = local(to)
        let path = Self.smoothPath(through: [p0] + waypoints.map(local) + [p2])
        let now = CACurrentMediaTime()
        let cruise = CAMediaTimingFunction(controlPoints: 0.35, 0.0, 0.45, 1)

        // —— The carrier: puffball cloud with the cat riding on top ——
        let cloudSize = max(48, petSpan * 0.5)
        let carrier = CALayer()
        carrier.bounds = CGRect(x: 0, y: 0, width: cloudSize * 1.6, height: cloudSize * 1.5)
        carrier.position = p0
        carrier.opacity = 0
        root.addSublayer(carrier)

        if let rider {
            let aspect = CGFloat(rider.width) / CGFloat(max(1, rider.height))
            let riderHeight = cloudSize * 0.95
            let riderLayer = CALayer()
            riderLayer.bounds = CGRect(x: 0, y: 0, width: riderHeight * aspect, height: riderHeight)
            riderLayer.contents = rider
            riderLayer.position = CGPoint(
                x: carrier.bounds.midX,
                y: carrier.bounds.midY + cloudSize * 0.42
            )
            carrier.addSublayer(riderLayer)

            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = -2.5
            bob.toValue = 2.5
            bob.duration = 0.3
            bob.autoreverses = true
            bob.repeatCount = .infinity
            riderLayer.add(bob, forKey: "bob")
        }

        let puffSpecs: [(dx: CGFloat, dy: CGFloat, size: CGFloat)] = [
            (0, -0.1, 1.0), (-0.45, -0.16, 0.62), (0.45, -0.14, 0.66), (0.08, 0.06, 0.52)
        ]
        for spec in puffSpecs {
            let puff = CALayer()
            let d = cloudSize * spec.size
            puff.bounds = CGRect(x: 0, y: 0, width: d * 1.4, height: d)
            puff.contents = Self.makeRadial(size: 40, color: NSColor(calibratedWhite: 0.97, alpha: 1))
            puff.position = CGPoint(
                x: carrier.bounds.midX + cloudSize * spec.dx,
                y: carrier.bounds.midY + cloudSize * spec.dy
            )
            carrier.addSublayer(puff)
        }

        let fly = CAKeyframeAnimation(keyPath: "position")
        fly.path = path
        fly.calculationMode = .paced
        fly.beginTime = now
        fly.duration = duration
        fly.timingFunction = cruise
        fly.fillMode = .both
        fly.isRemovedOnCompletion = false
        carrier.add(fly, forKey: "fly")
        carrier.position = p2

        let carrierFade = CAKeyframeAnimation(keyPath: "opacity")
        carrierFade.values = [0, 1, 1, 0]
        carrierFade.keyTimes = [0, 0.1, 0.9, 1]
        carrierFade.beginTime = now
        carrierFade.duration = duration
        carrierFade.fillMode = .both
        carrierFade.isRemovedOnCompletion = false
        carrier.add(carrierFade, forKey: "o")

        // —— Fluffy contrail ——
        let fluff = CAEmitterLayer()
        fluff.emitterPosition = p0
        fluff.emitterShape = .point
        fluff.renderMode = .oldestLast
        let tuft = CAEmitterCell()
        tuft.contents = Self.makeRadial(size: 24, color: NSColor(calibratedWhite: 0.95, alpha: 1))
        tuft.birthRate = 60
        tuft.lifetime = 0.5
        tuft.lifetimeRange = 0.18
        tuft.velocity = 6
        tuft.velocityRange = 8
        tuft.emissionRange = .pi * 2
        tuft.scale = 0.5
        tuft.scaleRange = 0.2
        tuft.scaleSpeed = 0.25
        tuft.alphaSpeed = -2.0
        fluff.emitterCells = [tuft]
        root.addSublayer(fluff)

        let fluffMove = CAKeyframeAnimation(keyPath: "emitterPosition")
        fluffMove.path = path
        fluffMove.calculationMode = .paced
        fluffMove.beginTime = now
        fluffMove.duration = duration
        fluffMove.timingFunction = cruise
        fluffMove.fillMode = .both
        fluffMove.isRemovedOnCompletion = false
        fluff.add(fluffMove, forKey: "move")
        fluff.emitterPosition = p2

        // —— Arrival: the cloud bursts into a soft poof ——
        let tArrive = max(0.05, duration - 0.05)
        for i in 0..<3 {
            let poof = CALayer()
            let d = cloudSize * (0.7 + CGFloat(i) * 0.35)
            poof.bounds = CGRect(x: 0, y: 0, width: d * 1.4, height: d)
            poof.contents = Self.makeRadial(size: 40, color: NSColor(calibratedWhite: 0.96, alpha: 1))
            poof.position = p2
            poof.opacity = 0
            root.addSublayer(poof)

            let puffOut = CAKeyframeAnimation(keyPath: "opacity")
            puffOut.values = [0, 0.8, 0]
            puffOut.keyTimes = [0, 0.3, 1]
            puffOut.beginTime = now + tArrive + Double(i) * 0.04
            puffOut.duration = 0.4
            puffOut.fillMode = .both
            puffOut.isRemovedOnCompletion = false
            poof.add(puffOut, forKey: "o")

            let puffGrow = CABasicAnimation(keyPath: "transform.scale")
            puffGrow.fromValue = 0.5
            puffGrow.toValue = 1.5
            puffGrow.beginTime = now + tArrive + Double(i) * 0.04
            puffGrow.duration = 0.4
            puffGrow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            puffGrow.fillMode = .both
            puffGrow.isRemovedOnCompletion = false
            poof.add(puffGrow, forKey: "s")
        }

        let arrive = DispatchWorkItem { [weak fluff] in
            fluff?.birthRate = 0
            completion()
        }
        completionWork = arrive
        DispatchQueue.main.asyncAfter(deadline: .now() + tArrive, execute: arrive)

        let teardown = DispatchWorkItem { [weak self] in self?.close() }
        teardownWork = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.6, execute: teardown)
    }

    // MARK: - 妖风缠绕 (twisting vortex strands)

    private func playVortex(
        from: CGPoint,
        to: CGPoint,
        petSpan: CGFloat,
        style: TeleportEffectStyle,
        completion: @escaping () -> Void
    ) {
        cancel()
        var randoms: [Double] = []
        for _ in 0..<12 { randoms.append(Double.random(in: 0...1)) }
        let waypoints = TeleportMath.travelWaypoints(from: from, to: to, unitRandoms: randoms)
        let pathLength = TeleportMath.travelPathLength(from: from, to: to, waypoints: waypoints)
        let duration = TeleportMath.travelDuration(distance: pathLength)

        let pad: CGFloat = 150
        var box = CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        ).insetBy(dx: -pad, dy: -pad)
        for waypoint in waypoints {
            box = box.union(CGRect(x: waypoint.x - pad, y: waypoint.y - pad, width: pad * 2, height: pad * 2))
        }

        let win = makeWindow(frame: box)
        window = win
        guard let root = win.contentView?.layer else {
            close()
            completion()
            return
        }
        func local(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - box.minX, y: p.y - box.minY)
        }
        let p0 = local(from)
        let p2 = local(to)
        let now = CACurrentMediaTime()
        let flyTiming = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.42, 1)

        // Sample the centerline, then braid strands around it: sine offsets
        // with phase shifts, enveloped so every strand converges at both
        // endpoints and the braid bulges mid-flight.
        let sampleCount = 26
        var centers: [CGPoint] = []
        for i in 0...sampleCount {
            let fraction = Double(i) / Double(sampleCount)
            centers.append(local(TeleportMath.pointAlongPolyline(
                from: from, to: to, waypoints: waypoints, fraction: fraction
            )))
        }
        let chordLength = max(1, hypot(to.x - from.x, to.y - from.y))
        let normal = CGVector(
            dx: -(to.y - from.y) / chordLength,
            dy: (to.x - from.x) / chordLength
        )
        let amplitude = min(28, max(14, petSpan * 0.16))
        let twists = 2.6

        func strandPath(phase: Double, amplitudeScale: CGFloat) -> CGPath {
            var points: [CGPoint] = []
            for (i, c) in centers.enumerated() {
                let t = Double(i) / Double(sampleCount)
                let envelope = sin(.pi * t)
                let offset = CGFloat(sin(2 * .pi * twists * t + phase) * envelope)
                    * amplitude * amplitudeScale
                points.append(CGPoint(x: c.x + normal.dx * offset, y: c.y + normal.dy * offset))
            }
            return Self.smoothPath(through: points)
        }

        // 妖风 palette: dusty gold and windswept grays. Ink trips swap in
        // 水墨: paper white, mid wash, deep ink — twisting brush strokes.
        let windGold: NSColor
        let windWarm: NSColor
        let windCool: NSColor
        if style == .ink {
            windGold = NSColor(calibratedWhite: 0.96, alpha: 1)
            windWarm = NSColor(calibratedRed: 0.5, green: 0.55, blue: 0.6, alpha: 1)
            windCool = NSColor(calibratedWhite: 0.22, alpha: 1)
        } else {
            windGold = NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.45, alpha: 1)
            windWarm = NSColor(calibratedRed: 0.86, green: 0.72, blue: 0.5, alpha: 1)
            windCool = NSColor(calibratedRed: 0.64, green: 0.62, blue: 0.58, alpha: 1)
        }

        let strandSpecs: [(color: NSColor, phase: Double, scale: CGFloat, width: CGFloat, alpha: CGFloat)] = [
            (windGold, 0, 1.0, 2.2, 0.85),
            (windWarm, 2.1, 1.0, 1.8, 0.7),
            (windCool, 4.2, 1.0, 1.6, 0.6),
            (windWarm, 1.05, -0.7, 1.2, 0.4)
        ]
        for (index, spec) in strandSpecs.enumerated() {
            let path = strandPath(phase: spec.phase, amplitudeScale: spec.scale)
            let delay = 0.025 * CFTimeInterval(index)

            let strand = CAShapeLayer()
            strand.path = path
            strand.fillColor = nil
            strand.strokeColor = spec.color.withAlphaComponent(spec.alpha).cgColor
            strand.lineWidth = spec.width
            strand.lineCap = .round
            strand.shadowColor = spec.color.cgColor
            strand.shadowRadius = 5
            strand.shadowOpacity = 0.8
            strand.shadowOffset = .zero
            strand.strokeEnd = 0
            root.addSublayer(strand)

            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.beginTime = now + delay
            draw.duration = duration
            draw.timingFunction = flyTiming
            draw.fillMode = .both
            draw.isRemovedOnCompletion = false
            strand.add(draw, forKey: "draw")
            strand.strokeEnd = 1

            let chase = CABasicAnimation(keyPath: "strokeStart")
            chase.fromValue = 0
            chase.toValue = 1
            chase.beginTime = now + delay + duration * 0.28
            chase.duration = duration
            chase.timingFunction = flyTiming
            chase.fillMode = .both
            chase.isRemovedOnCompletion = false
            strand.add(chase, forKey: "chase")
            strand.strokeStart = 1

            let head = CALayer()
            head.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
            head.contents = Self.makeRadial(size: 20, color: spec.color)
            head.position = p0
            head.opacity = 0
            root.addSublayer(head)

            let headFly = CAKeyframeAnimation(keyPath: "position")
            headFly.path = path
            headFly.calculationMode = .paced
            headFly.beginTime = now + delay
            headFly.duration = duration
            headFly.timingFunction = flyTiming
            headFly.fillMode = .both
            headFly.isRemovedOnCompletion = false
            head.add(headFly, forKey: "fly")
            head.position = p2

            let headFade = CAKeyframeAnimation(keyPath: "opacity")
            headFade.values = [0, 0.9, 0.9, 0]
            headFade.keyTimes = [0, 0.1, 0.88, 1]
            headFade.beginTime = now + delay
            headFade.duration = duration
            headFade.fillMode = .both
            headFade.isRemovedOnCompletion = false
            head.add(headFade, forKey: "o")
        }

        // Dust swirling along the centerline.
        let dustTrail = CAEmitterLayer()
        dustTrail.emitterPosition = p0
        dustTrail.emitterShape = .point
        dustTrail.renderMode = .oldestLast
        let grain = CAEmitterCell()
        grain.contents = Self.makeRadial(size: 12, color: .white)
        grain.color = windWarm.withAlphaComponent(0.9).cgColor
        grain.birthRate = 140
        grain.lifetime = 0.4
        grain.lifetimeRange = 0.15
        grain.velocity = 22
        grain.velocityRange = 26
        grain.emissionRange = .pi * 2
        grain.spin = 2
        grain.spinRange = 3
        grain.scale = 0.2
        grain.scaleRange = 0.12
        grain.alphaSpeed = -2.4
        dustTrail.emitterCells = [grain]
        root.addSublayer(dustTrail)

        let dustMove = CAKeyframeAnimation(keyPath: "emitterPosition")
        dustMove.path = Self.smoothPath(through: centers)
        dustMove.calculationMode = .paced
        dustMove.beginTime = now
        dustMove.duration = duration
        dustMove.timingFunction = flyTiming
        dustMove.fillMode = .both
        dustMove.isRemovedOnCompletion = false
        dustTrail.add(dustMove, forKey: "move")
        dustTrail.emitterPosition = p2

        // Arrival: the strands whip into a little dust flurry.
        let tArrive = max(0.05, duration - 0.05)
        let flurry = CAShapeLayer()
        let flurryW = min(120, max(44, petSpan * 0.5))
        flurry.bounds = CGRect(x: 0, y: 0, width: flurryW, height: flurryW * 0.4)
        flurry.position = p2
        flurry.path = CGPath(ellipseIn: flurry.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        flurry.fillColor = nil
        flurry.strokeColor = windGold.withAlphaComponent(0.85).cgColor
        flurry.lineWidth = 2
        flurry.lineDashPattern = [16, 12]
        flurry.opacity = 0
        root.addSublayer(flurry)

        let flurrySpin = CABasicAnimation(keyPath: "transform.rotation.z")
        flurrySpin.fromValue = 0
        flurrySpin.toValue = Double.pi * 1.6
        flurrySpin.beginTime = now + tArrive
        flurrySpin.duration = 0.4
        flurrySpin.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flurrySpin.fillMode = .both
        flurrySpin.isRemovedOnCompletion = false
        flurry.add(flurrySpin, forKey: "spin")

        let flurryOut = CAKeyframeAnimation(keyPath: "opacity")
        flurryOut.values = [0, 0.9, 0]
        flurryOut.keyTimes = [0, 0.3, 1]
        flurryOut.beginTime = now + tArrive
        flurryOut.duration = 0.4
        flurryOut.fillMode = .both
        flurryOut.isRemovedOnCompletion = false
        flurry.add(flurryOut, forKey: "o")

        let flurryGrow = CABasicAnimation(keyPath: "transform.scale")
        flurryGrow.fromValue = 0.3
        flurryGrow.toValue = 1.25
        flurryGrow.beginTime = now + tArrive
        flurryGrow.duration = 0.4
        flurryGrow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flurryGrow.fillMode = .both
        flurryGrow.isRemovedOnCompletion = false
        flurry.add(flurryGrow, forKey: "s")

        let arrive = DispatchWorkItem { [weak dustTrail] in
            dustTrail?.birthRate = 0
            completion()
        }
        completionWork = arrive
        DispatchQueue.main.asyncAfter(deadline: .now() + tArrive, execute: arrive)

        let teardown = DispatchWorkItem { [weak self] in self?.close() }
        teardownWork = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.65, execute: teardown)
    }

    // MARK: - 残影连跳 (shadow hops)

    private func playHops(
        from: CGPoint,
        to: CGPoint,
        petSpan: CGFloat,
        style: TeleportEffectStyle,
        rider: CGImage?,
        completion: @escaping () -> Void
    ) {
        cancel()
        let palette = Self.palette(for: style)
        var randoms: [Double] = []
        for _ in 0..<12 { randoms.append(Double.random(in: 0...1)) }
        let waypoints = TeleportMath.travelWaypoints(from: from, to: to, unitRandoms: randoms)
        let pathLength = TeleportMath.travelPathLength(from: from, to: to, waypoints: waypoints)
        let duration = max(0.42, min(0.7, pathLength / 2600))
        let hops = 3

        let pad: CGFloat = 150
        var box = CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        ).insetBy(dx: -pad, dy: -pad)
        for waypoint in waypoints {
            box = box.union(CGRect(x: waypoint.x - pad, y: waypoint.y - pad, width: pad * 2, height: pad * 2))
        }

        let win = makeWindow(frame: box)
        window = win
        guard let root = win.contentView?.layer else {
            close()
            completion()
            return
        }
        func local(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - box.minX, y: p.y - box.minY)
        }
        let now = CACurrentMediaTime()

        for i in 1...hops {
            let fraction = Double(i) / Double(hops + 1)
            let hopPoint = local(TeleportMath.pointAlongPolyline(
                from: from, to: to, waypoints: waypoints, fraction: fraction
            ))
            let begin = now + duration * fraction

            let holder = CALayer()
            if let rider {
                let aspect = CGFloat(rider.width) / CGFloat(max(1, rider.height))
                let height = petSpan * 0.55
                holder.bounds = CGRect(x: 0, y: 0, width: height * aspect, height: height)
                holder.backgroundColor = NSColor.white.cgColor
                let mask = CALayer()
                mask.frame = holder.bounds
                mask.contents = rider
                holder.mask = mask
            } else {
                holder.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
                holder.contents = Self.makeRadial(size: 26, color: palette.core)
            }
            holder.position = hopPoint
            holder.opacity = 0
            root.addSublayer(holder)

            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 0.9, 0]
            flash.keyTimes = [0, 0.4, 1]
            flash.beginTime = begin
            flash.duration = 0.16
            flash.fillMode = .both
            flash.isRemovedOnCompletion = false
            holder.add(flash, forKey: "o")

            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.92
            pulse.toValue = 1.05
            pulse.beginTime = begin
            pulse.duration = 0.16
            pulse.timingFunction = Self.hopTiming
            pulse.fillMode = .both
            pulse.isRemovedOnCompletion = false
            holder.add(pulse, forKey: "s")
        }

        let arrive = DispatchWorkItem { completion() }
        completionWork = arrive
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: arrive)

        let teardown = DispatchWorkItem { [weak self] in self?.close() }
        teardownWork = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.35, execute: teardown)
    }

    private static let hopTiming = CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.4, 1)

    /// Shared midpoint-quad smoothing.
    private static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        if points.count <= 2 {
            path.addLine(to: last)
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(
                x: (points[i].x + points[i + 1].x) / 2,
                y: (points[i].y + points[i + 1].y) / 2
            )
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: last)
        return path
    }

    /// Abort the flight (drag-cancel, pet hidden, teleport disabled).
    /// The pending completion does NOT fire.
    func cancel() {
        completionWork?.cancel()
        completionWork = nil
        sparkStopWork?.cancel()
        sparkStopWork = nil
        teardownWork?.cancel()
        teardownWork = nil
        close()
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }

    private func makeWindow(frame: CGRect) -> NSWindow {
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
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        let host = NSView(frame: CGRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        win.contentView = host
        win.orderFrontRegardless()
        return win
    }

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
}
