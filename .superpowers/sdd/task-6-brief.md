### Task 6: TeleportEffectRenderer (three styles + bubble)

**Files:**
- Create: `Sources/DesktopPet/TeleportEffectRenderer.swift`

**Interfaces:**
- Consumes: `TeleportEffectStyle` from DesktopPetCore; host `NSView`
- Produces:
  - `final class TeleportEffectRenderer`
  - `func playVanish(style: TeleportEffectStyle, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void)`
  - `func playAppear(style: TeleportEffectStyle, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void)`
  - `func cancel()`
  - `func showReminderBubble(text: String, near petView: NSView, duration: TimeInterval)`
  - `func dismissBubble()`

- [ ] **Step 1: Scaffold renderer with cancel + overlay**

```swift
import AppKit
import DesktopPetCore

@MainActor
final class TeleportEffectRenderer {
    private weak var host: NSView?
    private let overlay = CALayer()
    private var completionWorkItem: DispatchWorkItem?
    private var bubbleView: NSTextField?

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
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        overlay.removeAllAnimations()
        if let host {
            host.layer?.removeAllAnimations()
            host.alphaValue = 1
            host.layer?.opacity = 1
            host.layer?.transform = CATransform3DIdentity
        }
        dismissBubble()
    }

    private func finishAfter(_ duration: CFTimeInterval, completion: @escaping () -> Void) {
        let work = DispatchWorkItem { completion() }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // playVanish / playAppear / styles / bubble implemented in following steps
}
```

- [ ] **Step 2: Implement portal vanish/appear**

Durations: portal `0.65`, particles `0.75`, warp `0.55`.

Portal vanish sketch:

```swift
func playVanish(style: TeleportEffectStyle, onPet: NSView, completion: @escaping () -> Void) {
    cancel() // clear prior, but do not call completion
    // Re-add overlay if cancel cleared it — ensure overlay still attached
    ensureOverlay(on: onPet)
    switch style {
    case .portal: animatePortal(vanish: true, onPet: onPet, completion: completion)
    case .particles: animateParticles(vanish: true, onPet: onPet, completion: completion)
    case .warp: animateWarp(vanish: true, onPet: onPet, completion: completion)
    }
}
```

`animatePortal`:

- Add `CAShapeLayer` ellipse centered lower-mid of bounds; stroke cyan `NSColor(calibratedRed:0.35, green:0.85, blue:1, alpha:1)`, `shadowColor` violet
- Animate `transform.scale` 0.2→1.2 then stroke end collapse; animate pet `opacity` 1→0 and slight scale toward ring
- `finishAfter(0.65, completion)`

Appear: reverse opacity 0→1, ring open then close.

- [ ] **Step 3: Implement particles**

- Create `CAEmitterLayer` at pet center; `CAEmitterCell` with small square contents (1x1 cyan image), `birthRate` high briefly, `velocity` outward for vanish / negative for appear
- Fade pet opacity in parallel
- On completion remove emitter

- [ ] **Step 4: Implement warp**

- Expanding stroked circles (2–3 `CAShapeLayer`) with increasing path radius + fading opacity
- Pet: brief `CATransform3D` scale (1, 1.15, 1) then opacity → 0
- Appear: from scale 0.7 + opacity 0 → identity

- [ ] **Step 5: Reminder bubble**

```swift
func showReminderBubble(text: String, near petView: NSView, duration: TimeInterval = 3.5) {
    dismissBubble()
    guard let petView = host ?? petView as NSView? else { return }
    let label = NSTextField(labelWithString: text)
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
    // If bubble would go off screen top, place below:
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
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
        self?.dismissBubble()
    }
}

func dismissBubble() {
    bubbleView?.removeFromSuperview()
    bubbleView = nil
}
```

Override bubble hit testing by subclassing or:

```swift
final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
```

- [ ] **Step 6: Build**

Run: `swift build`

Expected: success

---

