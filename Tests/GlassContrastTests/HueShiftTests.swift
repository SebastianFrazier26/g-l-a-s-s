import Testing

@testable import GlassContrast

@Suite("Hue and chroma shifting")
struct HueShiftTests {
    let shifting = ContrastSolver(target: .apca(60))
    let fixed = ContrastSolver(target: .apca(60), hueShift: .lightnessOnly)

    // Mid blue over a mid-blue backdrop: lightness alone must climb to a near-white with almost no
    // chroma left; turning toward cyan, which has far more gamut room near white, keeps it a colour.
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
        #expect(sol.color.oklch.C > 2 * plain.color.oklch.C)
        #expect(hueDistance(sol.color.oklch.h, washedOut.text.oklch.h) <= 60 + 0.5)
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

    @Test func greyTextStaysGreyWithoutChromaGain() {
        let sol = shifting.solve(text: RGB(hex: 0x888888), background: .uniform(RGB(hex: 0x777777)))
        #expect(sol.meetsTarget && !sol.hueShifted && sol.color.oklch.C < 1e-3)
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
            #expect(hueDistance(n.h, o.h) <= policy.maxHueShift + 0.5)
            if strategy == .complementary, let bgHue = ContrastSolver.dominantHue(sample) {
                #expect(abs(signedHueDelta(from: bgHue, to: n.h)) >= abs(signedHueDelta(from: bgHue, to: o.h)) - 0.5)
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
