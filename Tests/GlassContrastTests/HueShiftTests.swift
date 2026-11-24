import Testing

@testable import GlassContrast

@Suite("Hue and chroma shifting")
struct HueShiftTests {
    let shifting = ContrastSolver(target: .apca(60))
    let fixed = ContrastSolver(target: .apca(60), hueShift: .lightnessOnly)

    // Mid blue over a mid-blue backdrop: lightness alone must climb to a near-white with almost no
    // chroma left; turning toward azure, which has more gamut room near white, keeps it a colour.
    // The backdrop's hue sits just above the text's, so the complementary rule also turns this way.
    let washedOut = (text: RGB(hex: 0x0066CC), bg: BackgroundSample.uniform(RGB(hex: 0x5577AA)))

    @Test func prefersLightnessOnlyWhenItKeepsTheColour() {
        let sol = shifting.solve(text: RGB(hex: 0x3355AA), background: .uniform(RGB(hex: 0x101418)))
        #expect(sol.meetsTarget && !sol.hueShifted)
        #expect(sol == fixed.solve(text: RGB(hex: 0x3355AA), background: .uniform(RGB(hex: 0x101418))))
    }

    @Test func shiftsHueWhenLightnessAloneWashesTheColourOut() {
        let plain = fixed.solve(text: washedOut.text, background: washedOut.bg)
        let sol = shifting.solve(text: washedOut.text, background: washedOut.bg)
        #expect(sol.meetsTarget && sol.hueShifted && sol.color.isInGamut)
        #expect(APCA.lightnessContrast(text: sol.color, background: RGB(hex: 0x5577AA)).magnitude >= 60 - 1e-9)
        // Measured 0.076 against 0.039. Under the old 60° cap it reached cyan at 0.15 (more than 2×).
        #expect(sol.color.oklch.C > 1.5 * plain.color.oklch.C)
        #expect(hueDistance(sol.color.oklch.h, washedOut.text.oklch.h) <= 45 + 0.5)
        let policy = shifting.hueShift, o = washedOut.text.oklch
        #expect(
            policy.cost(from: o, to: sol.color.oklch) < policy.cost(from: o, to: plain.color.oklch) - policy.advantage)
    }

    @Test func lightnessOnlyPolicyNeverShifts() {
        let sol = fixed.solve(text: washedOut.text, background: washedOut.bg)
        #expect(!sol.hueShifted)
        #expect(hueDistance(sol.color.oklch.h, washedOut.text.oklch.h) < 1)
    }

    @Test func costWithUnitWeightIsDeltaE() {
        var rng = SplitMix64(seed: 3)
        let p = HueShiftPolicy(strategy: .nearest, chromaLossWeight: 1)
        for _ in 0..<200 {
            let a = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit()),
                b = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            #expect(abs(p.cost(from: a.oklch, to: b.oklch) - a.oklab.distance(to: b.oklab)) < 1e-9)
        }
    }

    @Test func ownerDefaults() {
        let p = HueShiftPolicy.default
        #expect(p.strategy == .complementary && p.maxChromaGain == 0.03 && p.maxHueShift == 45)
        #expect(p.guardsSemanticRed)
    }

    @Test func greyTextOverGreyBackdropStaysGrey() {
        // No backdrop hue means no complement to tint toward.
        let sol = shifting.solve(text: RGB(hex: 0x888888), background: .uniform(RGB(hex: 0x777777)))
        #expect(sol.meetsTarget && !sol.hueShifted && sol.color.oklch.C < 1e-3)
    }

    @Test func greyTextTintIsTheBackdropComplementAndSubtle() {
        // Pull the search hard toward a tinted colour at an unrelated hue (via `previous`): the
        // answer may take on chroma, but only at the backdrop's complement and only up to the gain.
        let policy = HueShiftPolicy(strategy: .complementary, continuity: 10)
        let s = ContrastSolver(target: .apca(60), hueShift: policy)
        let backdrop = BackgroundSample.uniform(RGB(hex: 0x2244AA))
        let summary = backdrop.summary(coverage: s.coverage, luminance: s.target.luminance)
        let lure = OKLCH(L: 0.85, C: 0.03, h: 140).lab
        let cand = try! #require(
            s.shiftSearch(
                from: RGB(hex: 0x888888).oklch, toward: .lighter, summary, background: backdrop, previous: lure))
        let out = cand.color.oklch
        let complement = (ContrastSolver.dominantHue(backdrop)! + 180).truncatingRemainder(dividingBy: 360)
        #expect(out.C > 0.01 && out.C <= 0.03 + 1e-6)
        #expect(hueDistance(out.h, complement) < 0.5)
    }

    @Test func adjustedGreyTextOverAColouredBackdropTakesTheComplementaryTint() {
        let backdrop = BackgroundSample.uniform(RGB(hex: 0x2244AA))
        let sol = shifting.solve(text: RGB(hex: 0x888888), background: backdrop)
        let out = sol.color.oklch
        let complement = (ContrastSolver.dominantHue(backdrop)! + 180).truncatingRemainder(dividingBy: 360)
        #expect(sol.meetsTarget && sol.changed && sol.hueShifted)
        #expect(out.C > 0.02 && out.C <= 0.03 + 1e-6)
        #expect(hueDistance(out.h, complement) < 0.5)
        #expect(APCA.lightnessContrast(text: sol.color, background: RGB(hex: 0x2244AA)).magnitude >= 60 - 1e-9)
    }

    @Test func tintCanBeTurnedOff() {
        let s = ContrastSolver(
            target: .apca(60), hueShift: HueShiftPolicy(strategy: .complementary, tintsGreyText: false))
        let sol = s.solve(text: RGB(hex: 0x888888), background: .uniform(RGB(hex: 0x2244AA)))
        #expect(sol.meetsTarget && sol.color.oklch.C < 0.005)
        let plain = fixed.solve(text: RGB(hex: 0x888888), background: .uniform(RGB(hex: 0x2244AA)))
        #expect(plain.color.oklch.C < 1e-3)
    }

    @Test func readableGreyTextIsLeftAloneEvenOverColour() {
        // "Being adjusted" is the trigger: text that already passes keeps its exact colour.
        let sol = shifting.solve(text: RGB(hex: 0xF0F0F0), background: .uniform(RGB(hex: 0x102060)))
        #expect(!sol.changed && sol.color == RGB(hex: 0xF0F0F0))
    }

    @Test func tintFadesInWithBackdropChromaInsteadOfToggling() {
        // Backdrop chroma swept from grey to clearly blue: tint chroma rises continuously from zero.
        var last = 0.0
        for i in 0...60 {
            let c = Double(i) * 0.001
            let bg = OKLCH(L: 0.45, C: c, h: 264).rgb
            let sol = shifting.solve(text: RGB(hex: 0x777777), background: .uniform(bg))
            let tint = sol.color.oklch.C
            if c < 0.02 { #expect(tint < 1e-3) }
            if c >= 0.05 { #expect(tint > 0.02) }
            #expect(tint >= last - 2e-3)
            #expect(tint - last < 0.006, "jump at backdrop C=\(c)")
            last = tint
        }
    }

    @Test func semanticRedStaysRed() {
        // Over a blue backdrop the complementary arc from red points toward amber (measured: 72°
        // without the guard). The guard keeps it inside the red band.
        let text = RGB(hex: 0xE53935), bg = BackgroundSample.uniform(RGB(hex: 0x2050A0))
        let guarded = shifting.solve(text: text, background: bg).color.oklch.h
        let open = ContrastSolver(
            target: .apca(60), hueShift: HueShiftPolicy(strategy: .complementary, guardsSemanticRed: false)
        ).solve(text: text, background: bg)
        #expect(guarded >= 350 || guarded <= 45)
        #expect(open.hueShifted && open.color.oklch.h > 45)
    }

    @Test func nonRedsAreNotHeldToTheRedBand() {
        #expect(!HueShiftPolicy.isSemanticRed(RGB(hex: 0xFF8800).oklch))
        #expect(!HueShiftPolicy.isSemanticRed(RGB(hex: 0xAA8888).oklch))  // greyish pink: too little chroma
        #expect(HueShiftPolicy.isSemanticRed(RGB(hex: 0xFF0000).oklch))
    }

    @Test func preferredModeHoldsInsideTheHysteresisBand() {
        // Walk the backdrop from dark to mid grey and find where the unbiased answer starts shifting.
        let text = RGB(hex: 0x0066CC)
        func bg(_ g: Double) -> BackgroundSample { .uniform(RGB(r: g, g: g, b: g)) }
        var g = 0.10
        while g < 0.6 && !shifting.solve(text: text, background: bg(g)).hueShifted { g += 0.002 }
        #expect(g < 0.6, "expected a crossover on this ramp")
        // Entering shifted mode needs the full `advantage`; leaving it needs the same margin the
        // other way, so just short of the crossover a solver that was shifted stays shifted.
        #expect(!shifting.solve(text: text, background: bg(g - 0.002), preferredHueShift: false).hueShifted)
        #expect(shifting.solve(text: text, background: bg(g - 0.002), preferredHueShift: true).hueShifted)
    }

    @Test func adaptiveColourDoesNotFlickerAtTheCrossover() {
        let text = RGB(hex: 0x0066CC)
        func bg(_ g: Double) -> BackgroundSample { .uniform(RGB(r: g, g: g, b: g)) }
        var g = 0.10
        while g < 0.6 && !shifting.solve(text: text, background: bg(g)).hueShifted { g += 0.002 }
        var a = AdaptiveTextColor(original: text, solver: shifting)
        var flips = 0
        var last: Bool?
        for i in 0..<240 {
            _ = a.update(background: bg(g + (i % 2 == 0 ? 0.003 : -0.003)), dt: 1.0 / 60)
            if let last, last != a.hueShifted { flips += 1 }
            last = a.hueShifted
            #expect(a.current.isInGamut)
        }
        #expect(flips <= 1)
    }

    @Test(arguments: [HueShiftPolicy.Strategy.nearest, .complementary])
    func propertyClaimsAreTrueAndBoundsHold(strategy: HueShiftPolicy.Strategy) {
        var rng = SplitMix64(seed: 99)
        let policy = HueShiftPolicy(strategy: strategy, maxChromaGain: 0.05)
        let s = ContrastSolver(target: .apca(60), coverage: 1, hueShift: policy)
        for _ in 0..<250 {
            let text = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            let base = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            let colours = (0..<6).map { _ in
                RGB(
                    r: clamp01(base.r + (rng.unit() - 0.5) * 0.1), g: clamp01(base.g + (rng.unit() - 0.5) * 0.1),
                    b: clamp01(base.b + (rng.unit() - 0.5) * 0.1))
            }
            let sample = BackgroundSample(colors: colours)
            let sol = s.solve(text: text, background: sample)
            #expect(sol.color.isInGamut)
            let worst = colours.map { ContrastTarget.apca(60).score(text: sol.color, background: $0) }.min()!
            if sol.meetsTarget { #expect(worst >= 60 - 1e-9) }
            guard sol.hueShifted else { continue }
            let o = text.oklch, n = sol.color.oklch
            #expect(n.C <= o.C + policy.maxChromaGain + 1e-6)
            let bgHue = strategy == .complementary ? ContrastSolver.dominantHue(sample) : nil
            if o.C < 0.01 {
                // Grey text: hue is a free choice, so the rule is about where any tint points.
                if let bgHue, n.C > 0.005 { #expect(hueDistance(n.h, bgHue + 180) < 1) }
                continue
            }
            #expect(hueDistance(n.h, o.h) <= policy.maxHueShift + 0.5)
            if let bgHue {
                #expect(abs(signedHueDelta(from: bgHue, to: n.h)) >= abs(signedHueDelta(from: bgHue, to: o.h)) - 0.5)
            }
            if HueShiftPolicy.isSemanticRed(o) && (o.h >= 350 || o.h <= 45) {
                #expect(n.h >= 350 - 0.5 || n.h <= 45 + 0.5)
            }
        }
    }

    @Test func signedHueDeltaTakesTheShortWay() {
        #expect(signedHueDelta(from: 350, to: 10) == 20)
        #expect(signedHueDelta(from: 10, to: 350) == -20)
        #expect(signedHueDelta(from: 0, to: 180).magnitude == 180)
    }
}

@Suite("OKLCH spring")
struct PolarSpringTests {
    @Test func hueTravelsTheShorterArc() {
        let start = OKLCH(L: 0.6, C: 0.12, h: 350).lab, end = OKLCH(L: 0.6, C: 0.12, h: 20).lab
        var s = SpringSmoother(initial: start, omega: 12, space: .oklch)
        for _ in 0..<120 {
            let h = s.step(toward: end, dt: 1.0 / 60).lch.h
            #expect(h >= 349.9 || h <= 20.1, "went the long way: \(h)")
        }
        #expect(s.position.distance(to: end) < 1e-4)
    }

    @Test func chromaHoldsThroughAHueTurn() {
        // OKLab's straight line would dip to C = 0.12·cos(60°) = 0.06 halfway; the polar path doesn't.
        let start = OKLCH(L: 0.6, C: 0.12, h: 200).lab, end = OKLCH(L: 0.6, C: 0.12, h: 320).lab
        var s = SpringSmoother(initial: start, omega: 12, space: .oklch)
        for _ in 0..<120 { #expect(abs(s.step(toward: end, dt: 1.0 / 60).lch.C - 0.12) < 1e-9) }
    }

    @Test func greyStartTakesTheTargetHueWithoutSwinging() {
        let end = OKLCH(L: 0.7, C: 0.1, h: 140).lab
        var s = SpringSmoother(initial: OKLab(L: 0.5, a: 0, b: 0), omega: 12, space: .oklch)
        for _ in 0..<120 {
            let p = s.step(toward: end, dt: 1.0 / 60).lch
            if p.C > 1e-3 { #expect(abs(p.h - 140) < 1e-6) }
        }
    }

    @Test func frameRateIndependent() {
        let end = OKLCH(L: 0.8, C: 0.1, h: 30).lab
        var fine = SpringSmoother(initial: OKLCH(L: 0.4, C: 0.1, h: 250).lab, omega: 8, space: .oklch)
        var coarse = fine
        for _ in 0..<60 { _ = fine.step(toward: end, dt: 1.0 / 60) }
        for _ in 0..<6 { _ = coarse.step(toward: end, dt: 1.0 / 6) }
        #expect(fine.position.distance(to: coarse.position) < 1e-9)
    }

    @Test func settlesInAboutHalfASecond() {
        let start = OKLCH(L: 0.5, C: 0.15, h: 250).lab, end = OKLCH(L: 0.9, C: 0.12, h: 196).lab
        var s = SpringSmoother(initial: start, omega: 12, space: .oklch)
        for _ in 0..<33 { _ = s.step(toward: end, dt: 1.0 / 60) }
        #expect(s.position.distance(to: end) < 0.01 * start.distance(to: end) + 1e-3)
    }
}
