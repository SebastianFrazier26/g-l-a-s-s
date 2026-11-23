# g-l-a-s-s: agent notes

## Commands

| Task | Command |
|---|---|
| Build | `swift build` |
| Test | `swift test` |
| Lint | `swift format lint --strict --recursive Sources Tests Package.swift` |
| Format | `swift format format -i --recursive Sources Tests Package.swift` |
| Demo snapshot | `swift run GlassDemo --snapshot docs/img/demo-contact-sheet.png` (headless, needs no permissions) |

## Layout

- `Sources/GlassContrast`: the pure colour engine, Foundation only. **Never import AppKit or SwiftUI
  here.** All core logic goes in this target and is tested in `Tests/GlassContrastTests`.
- `Sources/GlassDemo`: SwiftUI demo. `--snapshot` draws its own glass approximation, because
  `ImageRenderer` can't draw system materials.
- `Sources/GlassOverlay`: window tracking, overlay
  window, Core Image compositor, text layer. It is tested in `Tests/GlassOverlayTests` with
  synthetic frames and buffers, so nothing there needs Screen Recording.
- `scripts/bundle-spike.sh` builds `build/GlassCaptureSpike.app`, ad-hoc signed. Rebuilding
  invalidates the user's Screen Recording grant, so don't rebuild it casually.
- `Sources/GlassCaptureSpike`: throwaway ScreenCaptureKit overlay proof. It must keep compiling.
  Don't run `--window` or `--request-access` unattended. `--check` and `--list` are safe.
- `docs/DESIGN.md`: the architecture options and feasibility. Option B was approved on 2026-11-23,
  relayed via the orchestrator. The owner's decisions (transparency, easing, contrast, signing) are
  in DESIGN §6b and `OwnerDefaults`. Packaging and repo visibility are still open.

## Conventions

- Swift 6 language mode with strict concurrency. Uses SwiftPM, with no third-party dependencies.
- Tests use swift-testing (`import Testing`). Property tests use the seeded `SplitMix64` in
  `TestSupport.swift`, so failures reproduce.
- Comments must be load-bearing only: the why, a rejected alternative, or a platform quirk.
- Date-stamp user-visible changes in `CHANGELOG.md`.
- Never call permission-*requesting* APIs at launch. Preflight calls only read state, so they are
  fine to use.
- Private SkyLight or CGS APIs stay out of the default build (see DESIGN §4, option C).
