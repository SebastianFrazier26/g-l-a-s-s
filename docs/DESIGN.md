# g-l-a-s-s: design and feasibility

> **Status: Option B approved 2026-11-23**, relayed via the orchestrating agent. Owner decisions on
> transparency, easing, contrast and signing are recorded in §6b. Packaging and repo visibility are
> still open.
>
> *Original status:* DRAFT, needs Sebastian's sign-off. The choice of architecture below is a
> recommendation, not a decision. Written 2026-11-23 by an agent working overnight. The web research
> is dated then; the platform facts marked *SDK-verified* were checked against the local
> macOS 26.4 SDK (Xcode 26.4, build 17E192, Swift 6.3) on this machine.

## 1. Intent

The request, in the user's own words: *"For clear background (liquid glass & other transparent
background modals/app windows) … auto-change colored text that goes over the background to a
contrasting color (should be gradually transient for easy-reading) & based on color theory."* It was
then clarified as *"a native mac app not a webapp … it applies to any window (and can make any window
transparent) and then contrast it."*

That breaks into three capabilities:

1. **Glass any window.** Make any app's window, not only ours, translucent or glassy.
2. **Keep text readable.** Text over that glass shifts toward a contrasting colour.
3. **Do it gently and on principle.** Changes ease in rather than flicker, and the colours are
   chosen with colour theory: a perceptual colour space, a standard contrast metric, and the
   smallest change that works (lightness first; hue and chroma only when that keeps the colour
   recognisably a colour, per the owner's decision of 2026-11-23, §6 item 2).

**Goals**
- Text stays readable over arbitrary, moving backgrounds.
- Colours change smoothly.
- Brand and semantic colours keep their hue wherever lightness alone does the job, and stay
  colourful (within a bounded hue turn) where it can't.

**Non-goals for v0**
- Windows and Linux.
- The App Store, which would likely be ruled out anyway (see §5).

**Anti-goals.** These would make it a failure even if it technically works:
- text that flickers between black and white;
- an overlay that steals clicks or lags badly enough to feel broken;
- requiring the user to weaken system security (SIP) for the core feature.

## 2. Why Swift, not the usual stack

The global norms list Python, C#, Rust and TypeScript, but none of them can drive this. Every
building block is an Apple framework with a first-class Swift API:
- ScreenCaptureKit
- AppKit window levels and click-through
- Core Animation and Metal compositing
- Vision OCR
- Accessibility
- SwiftUI and AppKit Liquid Glass (`glassEffect`, `NSGlassEffectView`)

Bridging to them from Rust or C# would add FFI and binding upkeep for no gain. So the code is:
- Swift 6 in strict-concurrency mode;
- SwiftPM only, with no third-party dependencies;
- split so the colour maths, `GlassContrast`, is pure Foundation code that is unit-testable on any
  runner and portable later, for example to a Rust core.

## 3. Feasibility findings

### 3.1 Changing another app's window alpha: possible only by injection, which needs SIP partly off

- macOS has no public API to change another process's window opacity.
- The private SkyLight and CoreGraphics Services calls (`CGSSetWindowAlpha` / `SLSSetWindowAlpha`)
  act through a WindowServer connection. *Inferred, not verified:* calls on windows your connection
  doesn't own are expected to be refused. That is why tools that do it inject code into a process
  that holds a privileged connection.
- **yabai** is the reference case. Its wiki lists *"window transparency (opacity)"* among the
  features that need its scripting addition, which is injected into Dock.app. That requires:
  - partially disabling SIP from Recovery:
    `csrutil enable --without fs --without debug --without nvram`;
  - on Apple Silicon, `sudo nvram boot-args=-arm64e_preview_abi`.

  Source: https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection
- An Apple Developer Forums thread asking how to do this through Accessibility concludes that
  yabai and Afloat can, but only with SIP disabled. Source:
  https://developer.apple.com/forums/thread/695451
- A yabai issue on Tahoe reports managed windows looking washed out, which suggests this area
  shifts between OS releases. Source: https://github.com/asmvik/yabai/issues/2762
- **Verdict:** real per-window alpha works, but only for users willing to reduce system security.
  It can't be shipped as the default behaviour.

### 3.2 Recolouring another app's text: impossible directly, possible in a mirror

- Accessibility (`AXUIElement`) can **read** text values and positions:
  - `kAXValueAttribute`;
  - `kAXBoundsForRangeParameterizedAttribute`, which gives per-range rectangles.

  It can't restyle text. Coverage is also uneven: native text views expose bounds, while many
  custom-drawn and Electron apps expose little. *Inferred, needs measuring.*
- The only general route is to **draw the text ourselves**, in an overlay, from a captured image of
  the window:
  1. Find the text regions, using Vision OCR or local contrast analysis.
  2. Build a glyph mask from the pixels that differ from the region's own background.
  3. Recolour that mask with the solver's colour.

  The target app never changes; we change what the user sees.
- Vision has a Swift-native `RecognizeTextRequest` in this SDK (*SDK-verified*). OCR latency per
  frame is *unmeasured*: expect tens of ms in `.fast` mode and more in `.accurate`. So OCR should
  run at a few Hz or only when content changes, not every frame.

### 3.3 Capturing a window and what is behind it: fully supported (ScreenCaptureKit)

*SDK-verified* `SCContentFilter` initialisers:
- `initWithDesktopIndependentWindow:` captures one window, even when it is covered.
- `initWithDisplay:excludingWindows:` captures the display minus chosen windows. Excluding the
  target and our own overlay gives *what is behind the target*, which becomes the glass backdrop.
- `initWithDisplay:excludingApplications:exceptingWindows:` is also available.

`SCStreamConfiguration` provides `sourceRect`, `minimumFrameInterval`, `queueDepth` and
`showsCursor`. Frames arrive as IOSurface-backed `CVPixelBuffer`s, which can go straight into
`CALayer.contents` or Metal without a copy.

### 3.4 Liquid Glass APIs: for our own windows only

*SDK-verified:*
- `NSGlassEffectView` and `NSGlassEffectContainerView`, both `API_AVAILABLE(macos(26.0))`, with
  `contentView`, `cornerRadius`, `tintColor` and `style`;
- SwiftUI `glassEffect` in SwiftUICore.

These render glass in **our** windows over whatever is behind them. They can't be applied to
another process's window. Apple's page:
https://developer.apple.com/documentation/appkit/nsglasseffectview

### 3.5 Permissions and distribution

- **Screen Recording.** Required for any ScreenCaptureKit capture.
  - Since Sequoia, the system re-prompts periodically. It moved from weekly to monthly during the
    2024 betas, and developers can't opt out.
    - https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/
    - https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly
  - Developers report renewed prompts on Tahoe point releases.
  - On 26.1, plain executables (not `.app` bundles) didn't appear in the Screen Recording list. So
    the real product **must be a bundled .app**, not the SwiftPM executable used for the spike.
    Source: https://developer.apple.com/forums/thread/807898
- **Accessibility.** Optional, only for AX text frames. Forum evidence conflicts on whether
  Accessibility works in a sandboxed or App Store app; `AXIsProcessTrusted` is reported as always
  false in sandboxed builds.
  - https://developer.apple.com/forums/thread/756130
  - https://developer.apple.com/forums/thread/749494
- **Distribution.**
  - Private SkyLight calls rule out the App Store.
  - Screen Recording plus Accessibility pushes toward **Developer ID signing and notarisation
    outside the App Store**, with the hardened runtime and no sandbox.
  - The injection route (§3.1) can't be offered as a normal install at all.
  - Notarisation docs:
    https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

### 3.6 Performance (estimates; to be measured in the spike)

- **Capture.** Two streams at 30 fps: the backdrop at half resolution (it gets blurred anyway) and
  the window at native resolution. Encoding is zero-copy into Core Animation or Metal. Expect a
  few percent of CPU and GPU per glassed window; pause when the window is hidden or occluded.
- **Solver** (measured in a release build on the dev machine, Apple Silicon): about 0.14 ms per text region against a
  solid background, and about 0.24 ms against a 256-pixel sample.
  - That is fine for tens of regions at 30 fps.
  - For hundreds, cache gamut-boundary lookups and re-solve only when a region's background
    histogram moves, which the deadband already detects.
- **Latency.** The mirror trails the real window by about 1 to 2 frames. Scrolling and typing will
  feel slightly behind; how much is the main thing to measure.

## 4. Architecture options

### Option A: "Glass host", glass only for content we render

A glass-windowed app whose own content (notes, a terminal, a reader, menu-bar widgets) uses
`GlassContrast` for its text. This is what `GlassDemo` already does.
- **Pros:** public APIs only, App Store-able, perfect text quality, no lag, no permissions.
- **Cons:** it doesn't meet "any window". Other apps are untouched.

### Option B: overlay mirror (recommended)

A click-through, borderless overlay window sits exactly over the target window. It composites:
1. the **backdrop**: a capture of what is behind the target, blurred and tinted, which is the glass;
2. the **window copy**: a capture of the target window, made translucent in one of two ways:
   - *uniform alpha*, which is simple; or
   - *background keying*, which makes only the window's own background colour transparent and keeps
     its content solid. Keying reads far better and is what "transparent window" usually means;
3. **text treatment**: per text region, sample the backdrop behind the glyphs, run the solver, and
   recolour the glyph mask, adding a scrim only when no single colour works.

The overlay ignores mouse events, so all input goes to the real window.
- **Pros:**
  - works on any app;
  - no SIP changes;
  - Developer ID distributable;
  - text colour is fully under our control.
- **Cons and limits:**
  - 1 to 2 frames of lag;
  - two permissions, Screen Recording (with the monthly prompt) and optionally Accessibility;
  - GPU and energy cost;
  - DRM or protected content is blacked out in captures;
  - menus, popovers, tooltips and IME panels are separate windows and would need their own
    handling;
  - window moves and resizes must be tracked (CGWindowList polling or AX observers);
  - Retina and multi-display coordinate handling;
  - the glyph mask is a heuristic, so antialiasing, emoji and images inside text regions need care.

### Option C: real alpha via injection, optionally through yabai

Set real window alpha through SkyLight from an injected Dock scripting addition. Rather than writing
our own injector, g-l-a-s-s could call an installed yabai (`yabai -m window <id> --opacity 0.7`).
- **Pros:** genuine transparency with zero lag, and the window stays live.
- **Cons:**
  - needs partially disabled SIP and the arm64e boot-arg;
  - can break with OS updates (see the Tahoe yabai issue);
  - can't be a mainstream product;
  - **text recolouring still needs the Option B overlay**, because alpha alone doesn't recolour
    text, and lowering alpha makes the text itself translucent too.

### Recommendation

**Build B, keep A as its proving ground, and treat C as an opt-in backend later.**
- B is the only option that meets "any window" without weakening system security.
- The colour engine is shared by all three, so nothing built tonight is wasted.
- A ships first anyway: the demo is the user's "simple script" core, proven in their own app.
- C can later plug in as an "if yabai is present, use real alpha" switch, but only with an explicit
  security warning.

## 5. The colour engine (built, decision-independent)

`Sources/GlassContrast`, with tests under `Tests/GlassContrastTests`.

**Colour spaces**
- sRGB ↔ linear (IEC 61966-2-1) ↔ OKLab/OKLCH, using Ottosson's matrices
  (https://bottosson.github.io/posts/oklab/).
- OKLCH keeps hue perceptually stable as lightness changes. HSL lightening shifts hue, for example
  blue drifts toward purple.

**Metrics**
- **WCAG 2 contrast ratio:** https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio
- **APCA 0.0.98G-4g Lc:** reference constants and outputs match apca-w3
  (https://github.com/Myndex/apca-w3). APCA models polarity and spatial frequency better, so it is
  the default (target Lc 60, the floor for content text).

**Solver**
- **Background reduction.** The background is a weighted colour sample. It is reduced to the
  darkest and lightest backgrounds at a coverage quantile (default 95%), so stray pixels don't force
  pure black or white.
- **Search.** For each polarity, bisect OKLCH lightness from the original toward 1 or 0:
  - hue is fixed;
  - chroma is kept unless the gamut forbids it.

  Near-white and near-black are the natural end of that search, not a special case.
- **Hue/chroma search (2026-11-23, §6 item 2).** For each feasible polarity, also search hue and
  chroma, and use that result only if it beats lightness-only by a margin. The algorithm is in §6.
- **Choice.** Pick the polarity with the smaller perceptual change (ΔE_OK). The preferred, current
  polarity gets a hysteresis bonus.
- **Scrim fallback.** If no colour works, for example when the background under one line spans
  black to white, add the faintest black or white veil that makes one colour work, capped at
  85% opacity.

**Temporal smoothing**
- A critically damped spring, stepped in closed form, so it is frame-rate independent and stable
  after stalls. Since 2026-11-23 it eases L, C and h separately in OKLCH, with hue on the shorter
  arc, so a hue-shifted retarget turns instead of fading through grey. The OKLab path is still
  available (`InterpolationSpace.oklab`).
- Three layers of hysteresis:
  - **Schmitt-trigger contrast:** aim 5% above the target and re-solve only when it is actually
    violated;
  - **a ΔE_OK deadband of 0.02**, about one just-noticeable difference (*from memory of
    CSS Color 4's gamut-mapping JND; verify*);
  - **polarity hysteresis**, plus the same kind of band between lightness-only and hue-shifted
    answers.

**Known trade-off.** While a transition eases, contrast can briefly dip below target (visible at
t = 1.6 s and 8.0 s in `docs/img/demo-contact-sheet.png`, Lc 57 against a target of 60). That is the
cost of "gradually transient". A fix, if wanted, is to ease faster when contrast is violated than
when it is merely improving. That is open question Q3.

## 5b. Option B spike status (branch `spike/overlay-b`, 2026-11-23)

Built ahead of sign-off so it can be evaluated. Discard the branch if B is rejected.
- **Tracking.**
  - *Verified on this machine:* CGWindowList returns other apps' window bounds and owner names with
    Screen Recording **not** granted.
  - So tracking needs no permission at all. That is why it polls (60 Hz) rather than using AX
    observers, which would need Accessibility plus a private call to map AX windows to window ids.
- **Compositing.** Core Image, with blending in linear light. Unit-tested against synthetic frames
  on the CPU renderer, and on the GPU through `CVPixelBuffer`s in the live path.
- **Text.**
  - Vision `.fast` OCR runs at 2 Hz and region analysis at 10 Hz.
  - Region identity is kept across OCR refreshes by box overlap (IoU ≥ 0.5).
  - Optional urgent easing, design question 3(b), is behind `--urgent-easing`. It is off by default
    (owner decision, §6b).
- **Unverified until it runs with permission:**
  - capture-to-overlay latency;
  - whether `order(.above, relativeTo:)` with another process's window number holds the overlay
    exactly above the target;
  - real-world keying quality on gradients and vibrancy;
  - CPU/GPU cost.

### MVP robustness (branch `mvp/overlay-b-robustness`)
- **Multiple displays.**
  - The backdrop is captured from the window's majority display, at that display's own scale.
  - When the window changes display, the stream's content filter switches.
  - The uncaptured part of a straddling window extends the nearest captured edge.
  - *Limitation:* for a straddling window, the backdrop on the minority display is synthesised,
    not real.
- **Menus and popovers.** These, along with any window in front of the target, become transparent
  holes in the overlay. This is robust even if z-ordering relative to another process misbehaves.
  - *Limitation:* text inside popovers is not glassed or recoloured, because they are separate
    windows. Glassing them too would mean a second overlay per child window.
- **Robustness.**
  - **Hidden or minimised windows:** compositing pauses.
  - **Fully covered windows:** compositing pauses.
  - **Capture errors:** restart with backoff.
  - **Revoked permission:** clean exit.
  - Capture itself keeps running while the window is paused. Stopping it would save more energy, at
    the cost of a slower resume; measure first.

## 6. Assumptions made overnight (correct any)

1. **Contrast metric:** APCA Lc 60 by default, with WCAG available. APCA isn't a W3C standard yet.
   WCAG 2 AA (4.5:1) is the legally referenced one.
2. **Hue:** ~~keep the original hue and move lightness only.~~ **Overturned by the owner on
   2026-11-23:** text may also shift hue and chroma when needed, on colour-theory grounds. The
   0.5 s settle and the macOS 14 minimum are unchanged. The algorithm (`HueShiftPolicy`,
   `Sources/GlassContrast/HueShift.swift`):
   - **Why hue can help at all.** APCA and WCAG score luminance only, so hue never rescues a
     background that white or black can't. If nothing passes, the scrim still applies. Hue buys a
     *smaller visible change*. Lightness-only pushed toward white or black runs out of gamut and
     drains chroma (a blue forced near-white becomes a pale grey-blue). Hues with more gamut room
     at that lightness keep the text colourful: cyan and yellow near white, blue and red near black.
   - **Lightness first.** The old lightness-only search runs unchanged. Its result stands unless
     the hue/chroma result is cheaper by `advantage` (0.03, about 1.5 JND).
   - **Cost.** ΔE_OK decomposed into ΔL, ΔC and ΔH, with chroma *loss* weighted ×2
     (`chromaLossWeight`). Plain ΔE (weight 1) almost never prefers a hue move: the needed
     luminance pins L, and hue changes luminance at fixed L only slightly. Measured: 0.292 against
     0.295 for #3355AA on #101418. At weight 3, red error text over dark grey turned orange, which
     the old rejection reason warns against.
   - **Search.** Find the boundary luminance once with a grey probe. The score depends on
     luminance only, so one probe serves every hue. Then, on a grid (hue every 15° within
     ±`maxHueShift`, which is 60°; five chroma levels up to the original chroma plus
     `maxChromaGain`, which is 0), bisect L onto that luminance. Keep in-gamut, re-verified
     candidates, then refine with a pattern search. About 0.2 ms per solve in release builds. The
     scrim's opacity bisection probes lightness-only, because feasibility doesn't depend on hue.
   - **Gamut.** sRGB, the gamut the engine already uses. Display P3 is not modelled yet.
   - **Stability.** There are two hysteresis guards. The mode band: entering shifted mode costs
     `advantage`, and so does leaving it. The `continuity` term (0.15 × ΔE to the last target)
     stops two near-equal hue branches from alternating. The spring eases in OKLCH on the shorter
     hue arc, and gamut-maps mid-transition points by chroma reduction.
   - **Options behind the setting.** `.nearest` (default), `.complementary` (only rotate away from
     the backdrop's mean hue), `.lightnessOnly` (the old behaviour). The spike takes
     `--hue-shift nearest|complementary|lightness`.
   - **Example.** #0066CC on #5577AA: lightness-only gives #D4E6FF (C 0.04); the default gives
     #10FCFE (C 0.15, a 60° turn to cyan). Both reach Lc 60. Mild cases, such as #3355AA on
     #101418, are unchanged.
3. **Smoothing:** about 0.5 s to settle (ω = 12 rad/s). That is slow enough to read as calm and fast
   enough not to linger unreadable.
4. **Minimum macOS:** macOS 14 for the package, and macOS 26 for Liquid Glass, with a material
   fallback below that.
5. **Distribution:** Developer ID outside the App Store. Nothing is signed yet.
6. **Repo visibility:** public by default, per the global norms. The repo is local only and not
   pushed.

## 6b. Owner decisions (2026-11-23)

Typed by the owner in the orchestrating session and relayed to the implementing agent.

| Question | Decision | Where it lives |
|---|---|---|
| Transparency mode | **Both, as a setting.** Keyed is the default: uniform alpha fades the window's own text with its background. | `TransparencySetting` (`Sources/GlassOverlay/Settings.swift`); spike `--mode keyed\|uniform`, `--alpha` |
| Urgent easing (Q3b) | **Always smooth.** Urgent easing stays off by default. The flag stays for experiments. | `OwnerDefaults.urgentOmega = nil`; spike `--urgent-easing` |
| Contrast target | **APCA Lc 60** (unchanged). | `OwnerDefaults.contrastTarget` |
| Signing | **Keep ad-hoc.** No Developer ID yet, so every rebuild of the .app needs Screen Recording granted again. | `scripts/bundle-spike.sh` |

This supersedes assumption 1 in §6 (now confirmed) and assumption 5 (Developer ID is deferred).
Still open: packaging and distribution channel, and repo visibility (§6.6).
