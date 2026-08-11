# Random Teleport Effects — Design Spec

**Date:** 2026-08-04  
**Status:** Approved for planning  
**App:** DesktopPet (macOS AppKit)

## Goal

Give the desktop cat an optional sci-fi hide/appear cycle: disappear with a short effect, reappear at another screen position (preferring corners across all displays), with a separate lower-frequency “near cursor” reminder mode that shows a customizable tip bubble.

## Non-goals

- Metal / SpriteKit / separate effect windows
- Changing clip assets or chroma-key pipeline
- Sound effects (can be added later)
- Reminder scheduling tied to clock time / calendar (interval-based only)

## Architecture

```
LibraryState (persisted settings)
        │
        ▼
LibraryWindowController ── toggles / slider / edit messages
        │
        ▼
TeleportController ── timer, state machine, landing math
        │
        ├── PetWindowController ── move window, cancel on drag
        └── TeleportEffectView (overlay) ── portal / particles / warp + bubble
```

### Units

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `LibraryState` fields | Persist feature flags and messages | `LibraryStore` encode/decode |
| Settings UI in `LibraryWindowController` | Enable/frequency/nudge/edit copy | `LibraryStore.update` |
| `TeleportController` | Scheduling, state machine, pick style & landing, cancel | `LibraryStore`, `PetWindowController` |
| `TeleportEffectRenderer` | Play vanish/appear CA animations | `PetContentView` layer tree |
| Reminder bubble | Show/hide tip text after cursor-nudge appear | Effect overlay or pet window |

`TeleportController` owns timing and decisions. The pet window owns frame geometry and drag. Effects are presentation-only and must be cancellable mid-flight.

## Settings & data model

Add to `LibraryState` (Codable, default-safe via `decodeIfPresent`):

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `teleportEnabled` | `Bool` | `false` | Master switch |
| `teleportFrequency` | `Double` | `0.5` | `0...1`, slow ↔ fast |
| `cursorNudgeEnabled` | `Bool` | `false` | Requires master on to be meaningful |
| `reminderMessages` | `[String]` | see below | One tip per line in editor |

Default messages:

```text
喝点水吧
站起来走走
看看远处放松一下
```

No separate slider for nudge frequency: nudge interval is **~4×** the current teleport interval (lower frequency). When both are enabled, a teleport tick rolls: with probability `1/4` prefer a cursor-nudge landing (if cursor position is usable); otherwise corner teleport. If nudge is disabled, always corner teleport.

### Frequency mapping

Let `f = clamp(teleportFrequency, 0, 1)`.

- Visible dwell before next vanish: `interval = lerp(60, 12, f)` seconds (default `f=0.5` → ~36 s, in the agreed mid range)
- Apply ±15% jitter per schedule so timing does not feel metronomic
- Hidden pause between vanish and appear: `hidden = lerp(2.0, 0.6, f)` seconds
- Each effect phase (vanish or appear): `~0.5...0.8` s depending on style (fixed per style, not user-tunable)

### Settings UI

In the existing library settings strip:

1. Checkbox「随机隐现」→ `teleportEnabled`
2. Slider「隐现频率」→ `teleportFrequency` (enabled only when master on)
3. Checkbox「鼠标附近提醒」→ `cursorNudgeEnabled` (enabled only when master on)
4. Button「编辑提醒文案…」→ sheet/panel: multiline `NSTextView`, one message per non-empty trimmed line; Save writes `reminderMessages`

Raising settings panel height as needed so controls fit without overlapping the clip list.

## Teleport flow

### State machine

```
idle ──(timer)──► vanishing ──► hidden ──► appearing ──► idle
  ▲                  │             │            │
  └──── cancel ◄─────┴─────────────┴────────────┘
```

Cancel sources:

- User starts dragging the pet (`mouseDown` that begins a move)
- Master switch turned off
- Status-menu hide pet (`orderOut`) — pause scheduling while hidden; cancel in-flight effect and leave pet hidden via menu semantics
- App quit (tear down cleanly)

On cancel during `vanishing` / `appearing` / `hidden`:

1. Stop all overlay animations / emitters
2. Restore pet content opacity/transform/mask to normal
3. Dismiss bubble if any
4. If cancel was drag during `hidden` or after position already moved: keep **current** window origin (if already teleported) or **pre-vanish** origin (if not yet moved). Rule: window origin only changes after vanish completes and before appear starts; cancel before that move restores visibility at the old origin; cancel after the move keeps the new origin and shows the pet there immediately
5. Return to `idle` and reschedule the next interval from now

### Sequence (happy path)

1. Timer fires in `idle`
2. Pick effect style uniformly: `portal` | `particles` | `warp`
3. Decide landing mode: corner vs cursor-nudge (rules above)
4. Play vanish at current origin
5. Enter `hidden`: pet not visible, hit-testing off for pet (or window ignores mouse for the pause)
6. Compute landing rect; `setFrameOrigin` to new position; persist `petOriginX` / `petOriginY`
7. Play appear with the **same** style
8. If landing was cursor-nudge and `reminderMessages` non-empty after trim: show bubble with random line for 3–4 s, then fade out
9. Return to `idle`; schedule next interval using the frequency mapping (including jitter)

Playback engine keeps running throughout; only presentation/position change.

### Interaction with existing flags

| Flag | Behavior |
|------|----------|
| `alwaysOnTop` | Unchanged |
| `clickThrough` | Teleport still runs. Drag-cancel only works when click-through is off. User can still disable teleport or hide via menu |
| Menu show/hide | While ordered out: teleport timer paused. On show: resume from `idle` with a fresh interval |
| Scale changes mid-teleport | Apply size as today; effects use current bounds |

## Landing rules

### Corner / edge preference (default teleport)

1. For each `NSScreen` in `NSScreen.screens`, take `visibleFrame` (excludes menu bar / Dock)
2. Build corner bands: rectangles inset from each corner covering roughly 8%–20% of width/height along each edge (four L-shaped or rectangular corner regions per screen)
3. Collect all corner regions across screens; pick one region uniformly; pick a random origin so the **entire pet window** stays inside that screen’s `visibleFrame`
4. Reject candidates whose center is within `1.5 ×` pet diagonal of the current center; retry up to N times, then accept best effort

### Cursor nudge

1. Read `NSEvent.mouseLocation` (global)
2. Find the screen containing the point (fallback: screen with largest intersection / main)
3. Sample a point on a ring ~120–200 pt from the cursor (not on the cursor), clamp so the full window stays in that screen’s `visibleFrame`
4. If clamping would place the pet too close to the cursor (< ~80 pt center distance), fall back to a corner landing for this tick and skip the bubble

### Persistence

After a successful position change (step 6 above), write the same UserDefaults keys already used by drag: `petOriginX`, `petOriginY`.

## Visual effects

Rendered on an overlay attached to `PetContentView` (`wantsLayer = true`). Pet image layer (or view opacity) participates in the animation; frame bitmaps are not modified.

### Shared

- Palette: cool cyan → soft violet energy, short-lived highlights
- Overlay idle when not teleporting: no emitters, empty sublayers
- All animations must respond to `cancel()` by removing animations and resetting state

### `portal`

- Elliptical energy ring (`CAShapeLayer` stroke + glow shadow) opens at pet feet / mid-body
- Pet scales slightly toward ring center and fades as ring closes
- Appear: reverse — ring opens at new site, pet emerges, ring closes

### `particles`

- Snapshot or mask pet bounds; drive `CAEmitterLayer` burst outward / upward while pet opacity → 0
- Appear: emitter inward / assemble then pet opacity → 1; stop emitter

### `warp`

- Brief radial ripple (`CAShapeLayer` expanding stroked circles) plus slight non-uniform scale / skew on pet layer, then fade
- Appear: ripple expands from center, pet springs from small scale + fade-in to identity

Duration target: **0.5–0.8 s** per phase.

## Reminder bubble

- Lightweight rounded label above or beside the pet (flip side if near screen top)
- Does not accept hits (`hitTest` → nil)
- Auto-dismiss after 3–4 s or on cancel / next teleport / drag
- Empty `reminderMessages`: still allow cursor-nudge appear, no text

## File / integration plan (implementation guidance)

Expected touch points:

- `Models.swift` — new `LibraryState` fields + decode defaults
- `LibraryWindowController.swift` — settings controls + message editor sheet
- `PetWindowController.swift` / `PetContentView` — drag cancel hook, overlay host, position API for controller
- New `TeleportController.swift` — timer + state machine + landing
- New `TeleportEffectRenderer.swift` (or nested types) — three styles + bubble
- `AppDelegate.swift` — construct/start/stop controller with store + pet window; pause on menu hide

## Testing / verification

Manual:

1. Master off → no teleport
2. Master on, frequency extremes → intervals feel slow vs fast
3. Multi-monitor → lands on secondary corners
4. Cursor nudge on → occasional near-cursor + bubble from custom lines
5. Drag mid-vanish / mid-hidden / mid-appear → immediate cancel semantics as specified
6. Click-through on → teleport continues; no drag cancel
7. Menu hide/show → timer pauses / resumes
8. Relaunch → settings and last position persist

## Decisions log

- Approach: Core Animation overlay in pet window (not Metal/SpriteKit, not fade-only)
- Effect style: random among portal / particles / warp each trip
- Frequency: user slider mapped to ~12–60 s dwell; default mid ≈ 36 s
- Landing: all screens, corner-biased; optional lower-frequency cursor nudge with editable tips
- Drag: cancel in-flight teleport immediately
- Nudge frequency: fixed ~4× rarer via 1/4 probability on each tick (no extra slider)
