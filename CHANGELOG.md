# Changelog

## 2026-11-23 (integration build, branch `mvp/integration`)

This merges `fix/overlay-perf` and `feat/hue-shift`, then applies the owner's decisions after the
first live run (DESIGN §6b).
- **One process glasses every window.** Use `--window TextEdit --window Notes --window Finder`.
  - Each display with a glassed window gets one shared backdrop capture. `BackdropRouter` crops
    it per window.
  - A window is skipped when ScreenCaptureKit's dirty rects show that nothing under it changed.
    `--all-backdrop-frames` turns the skipping off, for debugging.
  - `scripts/glass-test.sh` now launches a single process.
- **Window tracking is adaptive.** It polls at 60 Hz while the window moves and drops to 10 Hz
  after 0.5 s still.
- **Only complete frames are used.** Capture frames that ScreenCaptureKit marks idle or blank are
  ignored.
- **The log line has changed.** It is now one line per window every 5 s, and adds skipped backdrop
  frames and the tracker rate.
- **Keying is unchanged.** This is an owner decision: it is not OKLab.

## 2026-11-23 (first live run fixes, branch `fix/overlay-perf`)

These fixes are not yet in the signed .app. See `docs/perf.md`.
- **Every input triggers a composite.** That covers backdrop frames, text-style changes, and hole
  or pause changes, not only window frames. Before this, a static window was never drawn.
- **Text analysis idles on a static screen.** OCR re-runs only after the window changes.
- **The spike re-orders the overlay above its target** when clicking the target raises the target
  over it.
- **Window capture ignores the drop shadow.** Before this, the window copy came out shrunk and
  offset from the real window.
- **The spike logs per-second rates every 5 s,** replacing the misleading "fps composited" line.

## 2026-11-23 (hue shifting: owner follow-ups, branch `feat/hue-shift`)

- **Deliberate grey tint.** Grey text that has to be adjusted over a coloured backdrop now always
  takes a tint of the backdrop's complement, up to +0.03 chroma.
  - It is on by default. `HueShiftPolicy.tintsGreyText = false` turns it off.
  - Over a grey backdrop the text stays grey, and readable grey text is left alone.
  - The tint fades in with backdrop chroma rather than switching on and off.
- **Red guard confirmed** on by default. Brand orange turning yellow over navy is accepted, and
  there is no brand-hue protection list.
- **Known limitation, recorded in DESIGN §6 item 2.** The display gamut is read only when the
  window changes display.
- **Demo.** The demo sheet is regenerated.

## 2026-11-23 (hue shifting: owner answers, branch `feat/hue-shift`)

The owner answered the four follow-up questions. See DESIGN §6 item 2 and §6b.
- **Complementary is now the default strategy.** Hue turns only toward the complement of the local
  backdrop's hue. `nearest` and `lightnessOnly` remain as settings.
- **Hue turns are capped at 45°** (was 60°).
- **Chroma may rise by up to +0.03 OKLCH C.**
  - Grey text may take a tint, but only at the backdrop's complement, at most 0.03, and only over
    a chromatic backdrop.
  - In practice the minimum-change rule rarely picks one.
- **Semantic-red guard (on by default).** Saturated reds stay within 350°–45° and don't turn amber
  over blue backdrops. It narrows the owner's strategy and never overrides it.
- **Display P3 support.**
  - The solver works in the display's gamut (`ColorGamut`). P3 colours are carried as extended
    sRGB.
  - The overlay detects each display's gamut (`NSScreen.canRepresent(.p3)`). It re-solves when
    the window changes display, and renders and tags the live buffer in P3 or sRGB.
  - APCA and WCAG luminance accept extended values.
- **Search fix.** Hue/chroma candidates now sit on the gamut edge. Fixed chroma levels missed it
  and almost never beat lightness-only.
- **Demo.** The demo sheet is regenerated. Its "brand orange" line is renamed, because it now
  turns yellow over dark navy.

## 2026-11-23 (hue shifting, branch `feat/hue-shift`)

The owner overturned DESIGN §6 assumption 2 ("keep the original hue"). The 0.5 s settle and the
macOS 14 minimum are unchanged.
- **Text may shift hue and chroma, not just lightness.** `HueShiftPolicy` sets how
  (`Sources/GlassContrast/HueShift.swift`).
  - Lightness-only is still tried first.
  - A hue/chroma move is used only if it is clearly closer to the original colour, measured by
    ΔE_OK with chroma loss weighted ×2. In practice that is when lightness alone would wash the
    colour out near white or black.
  - Hue turns are capped at 60°, chroma never rises above the original, and the colour stays in
    the sRGB gamut. The follow-up entry above superseded these limits the same day.
- **Setting.** The strategies are `.nearest` (the default), `.complementary` and
  `.lightnessOnly`.
  - The default lives in `OwnerDefaults.hueShift`, and the policy is passed through
    `OverlayPipeline.Options.hueShift` and `TextLayerModel`.
  - The spike takes `--hue-shift`.
- **Smoother hue transitions.** The text-colour spring now eases in OKLCH, with hue on the shorter
  arc. The OKLab path remains as `InterpolationSpace.oklab`.
- **Less flicker.** New hysteresis keeps lightness-only and hue-shifted answers, and near-equal
  hue branches, from alternating.
- **API changes.** `ContrastSolution` gains `hueShifted`. `ContrastSolver.solve` and
  `solveWithScrim` take optional `preferredHueShift` and `previous` hints.

## 2026-11-23 (owner decisions, branch `mvp/overlay-b-robustness`)

These are the owner's decisions, recorded in DESIGN §6b.
- **Transparency is a setting, with both modes.** `TransparencySetting` offers `keyed` (the
  default) and `uniform`.
  - The spike's `--mode` now rejects unknown values instead of silently falling back to keyed.
  - Uniform `--alpha` is clamped to 0...1.
- **Always smooth.** Urgent easing stays off by default and remains available as
  `--urgent-easing`.
- **The contrast target stays APCA Lc 60.** It is now named in `OwnerDefaults`, which the pipeline
  uses as its default.
- **Signing stays ad-hoc.**

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
