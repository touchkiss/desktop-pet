import AppKit
import DesktopPetCore
import QuartzCore

/// 像素洪流 — the cat shatters into a grid of tiles at the origin, and the
/// shards immediately funnel into ONE thin glowing strand (the travel-streak
/// look) that flows along a single gentle arc; at the far end they fan back
/// out and reassemble into the cat, where the live video takes over. One
/// integrated journey on one oversized canvas window: no vanish / bridge /
/// appear seams.
@MainActor
final class TileSwarmRenderer {
    private var window: NSWindow?
    private var landWork: DispatchWorkItem?
    private var teardownWork: DispatchWorkItem?

    private static let shardGlow = NSColor(calibratedRed: 0.98, green: 0.84, blue: 0.5, alpha: 1)
    private static let trailTone = NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.35, alpha: 1)

    /// `fromRect` / `toRect` are the pet window rects in global screen
    /// coordinates (same size — the swarm carries the current cat).
    /// `onLanded` fires as the tiles lock in, so the live pet can take over
    /// underneath the fading swarm.
    func play(
        fromRect: CGRect,
        toRect: CGRect,
        snapshot: CGImage,
        onLanded: @escaping () -> Void
    ) {
        cancel()

        let chord = max(1, hypot(toRect.midX - fromRect.midX, toRect.midY - fromRect.midY))
        let total: CFTimeInterval = min(1.7, max(1.0, 0.85 + Double(chord) / 1400))
        // The strand's arc bulges at most 0.20 × chord (half of that in
        // actual deviation), so a slim margin is enough now.
        let margin = max(220, chord * 0.16)
        let box = fromRect.union(toRect).insetBy(dx: -margin, dy: -margin)

        let win = makeWindow(frame: box)
        window = win
        guard let root = win.contentView?.layer else {
            close()
            onLanded()
            return
        }

        func local(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX - box.minX,
                y: rect.minY - box.minY,
                width: rect.width,
                height: rect.height
            )
        }
        let a = local(fromRect)
        let b = local(toRect)
        let normal = CGVector(
            dx: -(b.midY - a.midY) / chord,
            dy: (b.midX - a.midX) / chord
        )
        let t0 = CACurrentMediaTime()
        let flyTiming = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.4, 1)

        let grid = 10
        let cellW = a.width / CGFloat(grid)
        let cellH = a.height / CGFloat(grid)
        let staggerSpan = total * 0.3
        let flight = total * 0.55

        // —— Shared stream: ONE gentle arc, same spirit as the travel
        // streak. Every shard funnels onto it right after the shatter,
        // rides it as a thin bundle (only a few points of lateral spread),
        // and fans back out to its landing cell at the far end. ——
        let aCenter = CGPoint(x: a.midX, y: a.midY)
        let bCenter = CGPoint(x: b.midX, y: b.midY)
        let control = TeleportMath.travelControlPoint(
            from: aCenter,
            to: bCenter,
            bulgeUnit: Double.random(in: 0...1),
            sideUnit: Double.random(in: 0...1)
        )
        func arcPoint(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(
                x: u * u * aCenter.x + 2 * u * t * control.x + t * t * bCenter.x,
                y: u * u * aCenter.y + 2 * u * t * control.y + t * t * bCenter.y
            )
        }
        func smoothStep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
            let t = min(1, max(0, (x - edge0) / max(0.0001, edge1 - edge0)))
            return t * t * (3 - 2 * t)
        }
        // Fractions of the flight spent merging in / breaking out.
        let convergeEnd: CGFloat = 0.22
        let divergeStart: CGFloat = 0.78
        let samples = 28

        for row in 0..<grid {
            for col in 0..<grid {
                let tile = CALayer()
                tile.bounds = CGRect(x: 0, y: 0, width: ceil(cellW) + 0.5, height: ceil(cellH) + 0.5)
                tile.contents = snapshot
                tile.contentsRect = CGRect(
                    x: CGFloat(col) / CGFloat(grid),
                    y: CGFloat(row) / CGFloat(grid),
                    width: 1 / CGFloat(grid),
                    height: 1 / CGFloat(grid)
                )
                tile.contentsGravity = .resize
                let aPos = CGPoint(
                    x: a.minX + (CGFloat(col) + 0.5) * cellW,
                    y: a.minY + (CGFloat(row) + 0.5) * cellH
                )
                let bPos = CGPoint(
                    x: b.minX + (CGFloat(col) + 0.5) * cellW,
                    y: b.minY + (CGFloat(row) + 0.5) * cellH
                )
                tile.position = aPos
                tile.shadowColor = Self.shardGlow.cgColor
                tile.shadowRadius = 4
                tile.shadowOpacity = 0
                tile.shadowOffset = .zero
                root.addSublayer(tile)

                // Funnel route: shatter cell → thin shared strand → landing
                // cell. `join` merges the shard onto the arc, `fan` peels it
                // off at the far end; in between it hugs the strand with a
                // tiny persistent lateral offset so the stream reads as a
                // bundle, not a wire.
                let dA = CGVector(dx: aPos.x - aCenter.x, dy: aPos.y - aCenter.y)
                let dB = CGVector(dx: bPos.x - bCenter.x, dy: bPos.y - bCenter.y)
                let lateral = CGFloat.random(in: -4...4)
                var points: [CGPoint] = []
                points.reserveCapacity(samples)
                for i in 0..<samples {
                    let t = CGFloat(i) / CGFloat(samples - 1)
                    let base = arcPoint(t)
                    let join = smoothStep(0, convergeEnd, t)
                    let fan = smoothStep(divergeStart, 1, t)
                    let hold = 1 - join
                    let inStream = min(join, 1 - fan)
                    points.append(CGPoint(
                        x: base.x + dA.dx * hold + dB.dx * fan + normal.dx * lateral * inStream,
                        y: base.y + dA.dy * hold + dB.dy * fan + normal.dy * lateral * inStream
                    ))
                }
                let route = CGMutablePath()
                route.move(to: points[0])
                for i in 1..<(points.count - 1) {
                    let mid = CGPoint(
                        x: (points[i].x + points[i + 1].x) / 2,
                        y: (points[i].y + points[i + 1].y) / 2
                    )
                    route.addQuadCurve(to: mid, control: points[i])
                }
                route.addLine(to: points[points.count - 1])

                let delay = (Double(row + col) / Double(2 * grid - 2)) * staggerSpan
                    + Double.random(in: 0...(total * 0.04))
                let begin = t0 + delay

                let fly = CAKeyframeAnimation(keyPath: "position")
                fly.path = route
                fly.calculationMode = .paced
                fly.beginTime = begin
                fly.duration = flight
                fly.timingFunction = flyTiming
                fly.fillMode = .both
                fly.isRemovedOnCompletion = false
                tile.add(fly, forKey: "fly")
                tile.position = bPos

                // Pixel-small while riding the strand, so the stream stays
                // thin; grows back while fanning out to land.
                let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
                shrink.values = [1.0, 0.85, 0.3, 0.3, 1.05, 1.0]
                shrink.keyTimes = [0, 0.08, 0.22, 0.78, 0.93, 1]
                shrink.beginTime = begin
                shrink.duration = flight
                shrink.fillMode = .both
                shrink.isRemovedOnCompletion = false
                tile.add(shrink, forKey: "s")

                let tumble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                let spin = CGFloat.random(in: -0.7...0.7)
                tumble.values = [0, spin, spin * 0.4, 0]
                tumble.keyTimes = [0, 0.35, 0.75, 1]
                tumble.beginTime = begin
                tumble.duration = flight
                tumble.fillMode = .both
                tumble.isRemovedOnCompletion = false
                tile.add(tumble, forKey: "r")

                // Bunched shards stack their glows, so each one glows softer
                // than before.
                let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
                glow.values = [0, 0.8, 0.8, 0]
                glow.keyTimes = [0, 0.15, 0.8, 1]
                glow.beginTime = begin
                glow.duration = flight
                glow.fillMode = .both
                glow.isRemovedOnCompletion = false
                tile.add(glow, forKey: "g")
            }
        }

        // —— One thin light trail along the shared strand (the travel-streak
        // look): the head draws it on, the tail chases and consumes it as
        // the last shards pass. Sits under every shard. ——
        let streamPath = CGMutablePath()
        streamPath.move(to: aCenter)
        streamPath.addQuadCurve(to: bCenter, control: control)

        let trail = CAShapeLayer()
        trail.path = streamPath
        trail.fillColor = nil
        trail.strokeColor = Self.trailTone.withAlphaComponent(0.55).cgColor
        trail.lineWidth = 2.5
        trail.lineCap = .round
        trail.shadowColor = Self.trailTone.cgColor
        trail.shadowRadius = 6
        trail.shadowOpacity = 0.8
        trail.shadowOffset = .zero
        trail.strokeEnd = 0
        root.insertSublayer(trail, at: 0)

        let trailDraw = CABasicAnimation(keyPath: "strokeEnd")
        trailDraw.fromValue = 0
        trailDraw.toValue = 1
        trailDraw.beginTime = t0
        trailDraw.duration = flight
        trailDraw.timingFunction = flyTiming
        trailDraw.fillMode = .both
        trailDraw.isRemovedOnCompletion = false
        trail.add(trailDraw, forKey: "draw")
        trail.strokeEnd = 1

        let trailChase = CABasicAnimation(keyPath: "strokeStart")
        trailChase.fromValue = 0
        trailChase.toValue = 1
        trailChase.beginTime = t0 + staggerSpan
        trailChase.duration = flight
        trailChase.timingFunction = flyTiming
        trailChase.fillMode = .both
        trailChase.isRemovedOnCompletion = false
        trail.add(trailChase, forKey: "chase")
        trail.strokeStart = 1

        // Energy flashes covering shatter and reassembly.
        func addFlash(at rect: CGRect, begin: CFTimeInterval, peak: Float, duration: CFTimeInterval) {
            let flash = CALayer()
            flash.frame = rect
            flash.backgroundColor = NSColor.white.cgColor
            let mask = CALayer()
            mask.frame = CGRect(origin: .zero, size: rect.size)
            mask.contents = snapshot
            flash.mask = mask
            flash.opacity = 0
            root.addSublayer(flash)

            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0, peak, 0]
            pulse.keyTimes = [0, 0.4, 1]
            pulse.beginTime = begin
            pulse.duration = duration
            pulse.fillMode = .both
            pulse.isRemovedOnCompletion = false
            flash.add(pulse, forKey: "o")
        }
        addFlash(at: a, begin: t0, peak: 0.65, duration: total * 0.18)
        addFlash(at: b, begin: t0 + total * 0.78, peak: 0.55, duration: total * 0.2)

        // Landing dust ring.
        let ring = CAShapeLayer()
        let ringW = b.width * 1.1
        let ringH = ringW * 0.26
        ring.bounds = CGRect(x: 0, y: 0, width: ringW, height: ringH)
        ring.position = CGPoint(x: b.midX, y: b.minY + ringH * 0.3)
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = Self.trailTone.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 2.2
        ring.opacity = 0
        root.addSublayer(ring)

        let ringGrow = CABasicAnimation(keyPath: "transform.scale")
        ringGrow.fromValue = 0.25
        ringGrow.toValue = 1.15
        ringGrow.beginTime = t0 + total * 0.85
        ringGrow.duration = 0.34
        ringGrow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ringGrow.fillMode = .both
        ringGrow.isRemovedOnCompletion = false
        ring.add(ringGrow, forKey: "grow")

        let ringOp = CAKeyframeAnimation(keyPath: "opacity")
        ringOp.values = [0, 0.9, 0]
        ringOp.keyTimes = [0, 0.25, 1]
        ringOp.beginTime = t0 + total * 0.85
        ringOp.duration = 0.34
        ringOp.fillMode = .both
        ringOp.isRemovedOnCompletion = false
        ring.add(ringOp, forKey: "o")

        // Hand off to the live pet just before the last shards settle, then
        // fade the whole canvas so the two overlap instead of gapping.
        let land = DispatchWorkItem { onLanded() }
        landWork = land
        DispatchQueue.main.asyncAfter(deadline: .now() + total * 0.95, execute: land)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = t0 + total * 0.97
        fade.duration = 0.22
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        root.add(fade, forKey: "fadeOut")

        let teardown = DispatchWorkItem { [weak self] in self?.close() }
        teardownWork = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.35, execute: teardown)
    }

    /// Abort (drag-cancel, pet hidden). The pending onLanded does NOT fire.
    func cancel() {
        landWork?.cancel()
        landWork = nil
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
}
