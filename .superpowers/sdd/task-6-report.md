# Task 6 Report: TeleportEffectRenderer

## Status
**Complete** — `Sources/DesktopPet/TeleportEffectRenderer.swift` created and `swift build` succeeds.

## Delivered

### `TeleportEffectRenderer` (@MainActor)
- `init(host:)` — attaches named `teleportOverlay` `CALayer` to `PetContentView`
- `cancel()` — cancels completion/bubble timers, clears overlay animations, resets pet opacity/transform, dismisses bubble
- `playVanish(style:onPet:completion:)` / `playAppear(style:onPet:completion:)` — style-specific CA animations

### Effect styles (cyan → violet palette)
| Style | Duration | Vanish | Appear |
|-------|----------|--------|--------|
| portal | 0.65s | Elliptical ring scales open; pet fades/scales toward center | Ring opens then closes; pet emerges |
| particles | 0.75s | `CAEmitterLayer` outward burst; pet opacity → 0 | Inward burst; pet opacity → 1 |
| warp | 0.55s | 3 expanding ripple rings + scale pulse; pet fades | Ripples expand; pet springs from 0.7 scale |

### Reminder bubble
- `PassthroughTextField` (`hitTest` → `nil`) for non-interactive label
- `showReminderBubble(text:near:duration:)` — dark rounded label above pet (flips below if near screen top), fades in, auto-dismiss ~3.5s
- `dismissBubble()` — removes view and cancels pending dismiss timer

### Cancel / re-entry safety
- `playVanish` / `playAppear` use `prepareForNewEffect` instead of calling full `cancel()` — cancels only the **previous** `completionWorkItem` before scheduling the new one; vanish resets pet presentation, appear preserves controller-set `alphaValue = 0`

## Build
```
swift build  →  success
```

## Notes for Task 7
- `TeleportController` can construct with `TeleportEffectRenderer(host: pet.effectHost)` and call `playVanish` / `playAppear` without a duration parameter (fixed per style internally).
- `cancel()` is safe to call from drag-cancel; it does not invoke stale completions.

## Concerns
- Particle emitter uses a 1×1 cyan bitmap; visual density may need tuning on large pet scales.
- Portal ring is positioned at ~38% height (lower-mid); may need adjustment per sprite aspect ratio.
- Bubble placement uses window `midY` vs screen `visibleFrame.midY` heuristic from brief — edge cases on multi-monitor corners untested manually.

## Fix: cancel() presentation-layer stuck opacity

**Problem:** Drag-cancel mid-vanish left pet invisible — CA animations with `fillMode = .forwards` kept presentation-layer opacity at 0 even after `resetPetView`.

**Changes:**
- `cancel()`: after `resetPetView(host)`, call `host.layer?.removeAllAnimations()` (overlay already cleared via `clearOverlay()` → `overlay.removeAllAnimations()`)
- `particleBirthRateWorkItem`: cancellable `DispatchWorkItem` for particle `birthRate = 0`; cancelled in `cancel()` and `prepareForNewEffect`

**Build:**
```
swift build  →  success (ok, build complete)
```
