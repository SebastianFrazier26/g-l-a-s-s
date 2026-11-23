# Changelog

## 2026-11-23 (MVP robustness, branch `mvp/overlay-b-robustness`)

Option B was approved, relayed via the orchestrating agent. Other design questions are still open.

- **Multiple displays.** `DisplayLayout` picks the display the target window is mostly on.
  - The backdrop is captured from that display, at that display's scale factor.
  - When the window moves to another display, the backdrop switches with it.
  - A window straddling two displays gets a real backdrop for the captured part, and the nearest
    edge is extended over the rest.
- **Menus, popovers and covering windows.** `Occlusion` finds windows in front of the target: the
  app's own menus, popovers and sheets, plus other apps' windows.
  - The overlay cuts holes there, so those windows stay visible and clickable as themselves.
  - Compositing pauses while the target is fully covered.
- **Robustness.**
  - The tracker reports `.hidden`, covering minimised windows, other Spaces and hidden apps; the
    overlay hides and compositing pauses until the window returns.
  - Capture streams that stop with an error restart with exponential backoff (`RestartPolicy`).
  - Revoking Screen Recording exits cleanly with a message.

## 2026-11-23 (later): branch `spike/overlay-b`, pending architecture sign-off

### New `GlassOverlay` library (design option B)
- `WindowTracker` follows a window's moves, resizes and closing. It polls CGWindowList, which
  needs no permission.
- `OverlayWindow`: borderless and click-through, ordered just above the target window.
- `GlassCompositor` is a Core Image pipeline:
  - blurred, tinted backdrop;
  - window copy, either at uniform alpha or with its background colour keyed out;
  - per-region glyph recolour and scrim.
- `TextLayerModel` and `VisionTextDetector` handle text:
  - Vision OCR finds text regions;
  - region analysis picks out the window background and the text's ink colour;
  - a photo guard skips regions that look like images;
  - each region gets its own adaptive colour.
- `OverlayPipeline` is the thread-safe glue between capture, analysis and compositing.

### Other changes
- `AdaptiveTextColor.urgentOmega` is a draft of design question 3b, off by default: fast easing
  while the text on screen is unreadable.
- `GlassCaptureSpike` is rebuilt on `GlassOverlay`.
- `scripts/bundle-spike.sh` builds a signed .app, so Screen Recording can be granted to it.

## 2026-11-23

### Scaffold
- SwiftPM package with CI: lint, build and test on a macOS runner.
- MIT licence.

### Colour engine: `GlassContrast`
- sRGB, linear, OKLab and OKLCH conversions.
- WCAG 2 contrast ratio and APCA 0.0.98G-4g.
- Solver that preserves hue while meeting contrast across background distributions, with a scrim
  fallback when no colour can.
- Spring smoothing with hysteresis.

### `GlassDemo`
- SwiftUI glass panel over an animated backdrop.
- Headless `--snapshot` contact sheet.

### `GlassCaptureSpike`
- ScreenCaptureKit overlay that mirrors another app's window over its blurred backdrop.
- Compile-only so far, because it needs Screen Recording permission.

### `docs/DESIGN.md`
- Feasibility research, three architecture options, and a recommendation. Pending sign-off.
