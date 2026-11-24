# First live run: performance and functional findings (2026-11-23)

The first run with Screen Recording granted used `scripts/glass-test.sh`, in keyed mode, with one
`GlassCaptureSpike` instance each for TextEdit, Notes and Finder. The machine was an M5 MacBook on
macOS 26.5.1 in **dark mode**.

## What was measured

| | CPU (30 s avg) | RSS |
|---|---|---|
| pid 25688 (TextEdit) | 25.2% | 61 MB |
| pid 25722 (Finder) | 32.3% | 71 MB |
| pid 25712 (Notes) | 34.4% | 70 MB |
| WindowServer | 24.1% | |

- **Log.** `0.1`, `0.0`, `2.5` and `0.1 fps composited`.
- **Instant `ps`, during investigation.** 8.5%, 24.0% and 20.1% CPU.
- **Owner's report.**
  - The windows did not turn to glass.
  - Clicking a window turned the screen behind it black and white.
  - The text never changed colour.

`sample <pid> 5` was taken for each process, at about 4,300 samples per thread. Counts are
inclusive and approximate. The analysis numbers are summed over the async frames they ran on.

| Hot path | 25688 | 25712 | 25722 |
|---|---|---|---|
| `OverlayPipeline.analyse` (whole loop) | ~430 | ~1040 | ~850 |
| of which `TextLayerModel.update` (pow/cbrt/OKLab, sort, gamut) | ~140 | ~610 | ~500 |
| of which `VNRecognizeTextRequest` (OCR) | ~110 | ~170 | ~160 |
| `WindowTracker.poll`, main thread (`SLWindowListCopyWindowInfo` round-trips) | 238 | 218 | 257 |
| `ingestWindow` (actual compositing) | 12 | 101 | 126 |

## Root causes

1. **Nothing was drawn until the window changed.** This is the main reason the windows didn't turn
   to glass.
   - The overlay composited only when a *window* frame arrived.
   - ScreenCaptureKit delivers a frame only when pixels change, so a static window sends one
     frame at start.
   - That first frame usually arrived before the first backdrop frame. The composite was then
     skipped, the overlay stayed fully transparent, and the plain window showed through.
   - Backdrop changes never triggered a composite, so the glass couldn't follow what moved
     behind the window.
   - "0.1 fps composited" was this stall. The figure itself was misleading: it was printed only
     when a frame happened to be presented, and divided by however long it had been since the
     last one.
2. **Clicking a window put its overlay behind it.**
   - The overlay is ordered above its target only when the target's frame changes.
   - Clicking activates the target's app, which raises the window above the overlay without
     moving it, so the overlay was never re-ordered.
3. **The "black and white" screen (inferred, not observed).**
   - A click changes the pixels of *every* test window: the clicked one becomes active and the
     others go inactive. That produced the first real composite for the overlays of the windows
     *behind* the clicked one.
   - In dark mode, those windows' backgrounds, and their dark-grey chrome, are keyed away to
     frosted glass: a blurred backdrop plus a light 18% white tint. Their light text is
     recoloured near-black for contrast.
   - Behind the window you clicked, that reads as greyish glass with black text. The headless
     reproduction below shows the same result: glass, plus text going from #DEDEDE to black.
   - Nothing in the code desaturates the image. No greyscale or colour-control filter exists
     anywhere in `Sources`.
4. **The text did change colour, but it was rarely shown.**
   - Styles were computed at 10 Hz, but they reach the screen only through a composite. Per (1),
     composites almost never happened.
   - The clicked window's own overlay sat behind it, per (2).
5. **The window copy was misaligned.**
   - Single-window capture includes the drop shadow by default (`ignoreShadowsSingleWindow` is
     false).
   - The shadowed image was scaled down into the window-sized buffer, so the copy came out
     smaller than the real window and offset from it.
6. **CPU was spent on a frame nobody saw.**
   - The analysis loop ran forever at 10 Hz: OCR every 0.5 s, two Core Image read-backs, and
     the colour model on every tick. It ran even when no frame had arrived and the colours had
     settled, which is about 2/3 of each process's CPU.
   - The 60 Hz `CGWindowList` poll costs about 5% of a core per process. Most of that is mach
     round-trips to WindowServer, so it also shows up in WindowServer's 24%, together with three
     display backdrop streams and three window streams.

Keyed mode does work with dark-mode windows. The pipeline was fed a synthetic dark window (#1E1E1E
background, #2B2B2B sidebar, #DEDEDE text) over an orange backdrop, headlessly. The background and
sidebar became orange-tinted glass, and the text went black. That case is now a regression test:
`darkModeWindowTurnsToGlassAndTextIsRecoloured`. The live failure was in *when* frames were drawn
and *where* the overlay sat, not in the compositing itself.

## Fixes (branch `fix/overlay-perf`, not yet in the signed .app)

- `OverlayPipeline` re-composites on every input: window frames, backdrop frames, style changes
  (the `startAnalysis(onChange:)` callback), and hole or pause changes (`setGeometry` and
  `setPaused` now report whether anything changed). Renders are serialised.
- Analysis idles when no frame has arrived since the last run and the easing has settled. OCR re-runs only
  when the window frame actually changed. On a static screen the steady-state analysis cost is ~0.
- At 10 Hz, the spike checks whether the overlay is still in front of its target
  (`Occlusion.isInFront`) and re-orders it if not.
- Window capture sets `ignoreShadowsSingleWindow = true`.
- The spike now logs real rates every 5 s, for example `per s: window 0.2, backdrop 1.0,
  composited 1.2, presented 1.2, analysis 0.4, ocr 0.2; z-reorders 0`.

Tests cover each fix headlessly: 119 tests passing, and lint is clean.

## Still unverified / open

- **Cross-app z-ordering.** `order(.above, relativeTo:)` against another app's window from a
  background accessory app is not verified on macOS 26. The new `z-reorders` counter will show
  whether it sticks. If it climbs every tick, the fallback is `.floating` level plus hiding while
  the target app is inactive.
- **Owner decisions:**
  - **Tracker poll rate.** 60 Hz costs ~5% of a core per window, plus WindowServer load. Dropping
    to 10 Hz when idle and 60 Hz while moving would cut most of that, but costs up to 100 ms of
    lag at the start of a drag.
  - **One process for all windows.** Today each window gets its own process, and three processes
    mean three backdrop streams. One process could share a single display stream.
  - **Dark-mode keying is loose.** The key tolerance is measured in linear light, which compresses
    dark colours. In dark mode, every grey up to about #303030 keys out completely, so dark
    selection highlights and toolbars vanish into the glass. Measuring the distance in OKLab
    instead would make the tolerance perceptual.
  - **Capture frame-rate cap.** Leave it at 30. Frames arrive only on change, so the cap matters
    only while something is animating.
- **Verification needs a rebuilt app.** Rebuilding re-signs the app, so the owner must re-grant
  Screen Recording.
