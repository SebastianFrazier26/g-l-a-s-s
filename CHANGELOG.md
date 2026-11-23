# Changelog

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
