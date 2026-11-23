# Overlay MVP Implementation Plan (DRAFT: blocked on DESIGN.md sign-off)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the `GlassCaptureSpike` into a bundled menu-bar app that glasses one chosen window and
keeps its text readable.

**Architecture:** This is Option B in `docs/DESIGN.md`. It uses two ScreenCaptureKit streams, one
for the backdrop behind the target and one for the target window. A click-through overlay window
composites them in Metal. Text regions come from Vision OCR at a low rate, and each region gets a
glyph mask recoloured with `GlassContrast`.

**Tech Stack:** Swift 6, SwiftPM plus an Xcode app target for the bundle, ScreenCaptureKit, Metal,
Vision, AppKit.

**Spec:** `docs/DESIGN.md`

## Global Constraints
- macOS 14 minimum. Liquid Glass UI is used only on macOS 26 or later.
- No third-party dependencies.
- Developer ID distribution with the hardened runtime. No App Sandbox.
- Never call private SkyLight or CGS APIs in the default build.
- Request each permission only from an explicit user action, never at launch.
- Hold 30 fps. Pause capture when the target is minimised or occluded.

## Review Focus
1. **Target window moves or resizes.** The overlay must follow within about 1 frame, with no stale
   frame left at the old position.
2. **Target window closes or its app quits.** The overlay disappears and streams stop, with no
   crash and no orphan overlay.
3. **Screen Recording is revoked or the monthly re-prompt is declined.** The app degrades to a
   clear "paused, needs permission" state.
4. **Multi-display and mixed scale factors.** The overlay sits pixel-exact on a 1x external display
   and on a 2x built-in one.
5. **Text regions over images or emoji.** The glyph mask must not recolour photographs.
   - Add a test: a region whose pixels have a colour count above a threshold is classed "non-text".

---

### Task 1: Bundled app shell plus permission flow
**Files:** Create `App/GlassApp.xcodeproj` (or `Package.swift` plus a bundling script, the
user's choice: Q5) and `Sources/GlassApp/PermissionModel.swift`. Tests go in `Tests/GlassAppTests/`.

- `enum PermissionState { case unknown, granted, denied }`
- `PermissionModel.screenRecording()` uses `CGPreflightScreenCaptureAccess`.
- `PermissionModel.request()` calls `CGRequestScreenCaptureAccess` only from a button.
- Test: a model with a stubbed preflight maps `true`/`false` to `.granted`/`.denied`.

### Task 2: Window tracker
**Files:** `Sources/GlassApp/WindowTracker.swift`.

- `struct TrackedWindow { id: CGWindowID; frame: CGRect }`
- `WindowTracker.frames(for ids: [CGWindowID]) -> [CGWindowID: CGRect]` uses
  `CGWindowListCopyWindowInfo`.
- `func cgToAppKit(_ r: CGRect, mainScreenHeight: CGFloat) -> CGRect` converts between coordinate
  systems.
- Tests: coordinate flip values; a vanished id is absent from the result.

### Task 3: Backdrop plus window composite in Metal
**Files:** `Sources/GlassApp/Compositor.swift` and `Shaders.metal`.

- Inputs are two IOSurfaces. Uniforms: `blurRadius`, `tint` (RGBA), `windowAlpha`, and `keyColor` +
  `keyTolerance` for background keying.
- Test: on CPU reference images, a keyed pixel equal to `keyColor` becomes alpha 0, and a pixel
  differing by more than tolerance stays opaque.

### Task 4: Text regions plus glyph mask plus recolour
**Files:** `Sources/GlassApp/TextRegions.swift`.

- `func glyphMask(region: PixelRegion, background: RGB, tolerance: Double) -> [Bool]`
- `func isLikelyText(region: PixelRegion) -> Bool` uses the colour-count heuristic from Review
  Focus item 5.
- Wire `AdaptiveTextColor` per region (keyed by OCR box identity with IoU of at least 0.5 across
  refreshes).
- Tests: a synthetic black-on-white "text" region gives a mask covering only the dark pixels, and a
  noise image classifies as non-text.

### Task 5: Measure
Record capture-to-display latency, CPU and GPU percentages, and energy impact (Activity Monitor)
for 1 and 3 glassed windows in `docs/perf.md`. Run it with the user present: it needs permissions.
