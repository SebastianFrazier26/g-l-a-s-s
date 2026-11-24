import Testing

@testable import GlassContrast

@Suite("Background distribution")
struct BackgroundTests {
    @Test func uniformSummaryIsTheColour() {
        let c = RGB(hex: 0x336699)
        let s = BackgroundSample.uniform(c).summary(coverage: 0.95)
        #expect(s.darkest == c && s.lightest == c)
    }

    @Test func quantilesIgnoreOutliers() {
        // 98 mid greys plus one black and one white pixel: at 95% coverage the outliers are ignored.
        let colours = Array(repeating: RGB(hex: 0x808080), count: 98) + [RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)]
        let s = BackgroundSample(colors: colours).summary(coverage: 0.95)
        #expect(s.darkest == RGB(hex: 0x808080))
        #expect(s.lightest == RGB(hex: 0x808080))
    }

    @Test func fullCoverageIncludesExtremes() {
        let colours = [RGB(hex: 0x202020), RGB(hex: 0x808080), RGB(hex: 0xE0E0E0)]
        let s = BackgroundSample(colors: colours).summary(coverage: 1)
        #expect(s.darkest == RGB(hex: 0x202020) && s.lightest == RGB(hex: 0xE0E0E0))
    }

    @Test func weightsShiftQuantiles() {
        let colours = [RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)]
        let s = BackgroundSample(colors: colours, weights: [1, 99]).summary(coverage: 0.95)
        #expect(s.darkest == RGB(hex: 0xFFFFFF))
    }

    @Test func emptySampleFallsBackToMidGrey() {
        let s = BackgroundSample(colors: []).summary(coverage: 0.95)
        #expect(s.darkest == RGB(hex: 0x808080) || abs(s.darkest.r - 0.5) < 0.01)
    }
}

@Suite("Contrast solver")
struct SolverTests {
    let solver = ContrastSolver(target: .apca(60))

    @Test func leavesAlreadyReadableTextAlone() {
        let text = RGB(hex: 0x111111)
        let sol = solver.solve(text: text, background: .uniform(RGB(hex: 0xFFFFFF)))
        #expect(sol.color == text)
        #expect(!sol.changed && sol.meetsTarget)
    }

    @Test func darkBackgroundPushesTextLighterAndKeepsHue() {
        let text = RGB(hex: 0x3355AA)  // a mid blue, unreadable on near-black
        let sol = solver.solve(text: text, background: .uniform(RGB(hex: 0x101418)))
        #expect(sol.meetsTarget && sol.changed && sol.polarity == .lighter)
        #expect(sol.color.oklch.L > text.oklch.L)
        #expect(hueDistance(sol.color.oklch.h, text.oklch.h) < 1.0)
    }

    @Test func lightBackgroundPushesTextDarker() {
        let text = RGB(hex: 0xFFCC66)
        let sol = solver.solve(text: text, background: .uniform(RGB(hex: 0xF4F4F0)))
        #expect(sol.meetsTarget && sol.polarity == .darker)
        #expect(sol.color.oklch.L < text.oklch.L)
        #expect(hueDistance(sol.color.oklch.h, text.oklch.h) < 1.0)
    }

    @Test func changeIsMinimal() {
        // Lightness found by bisection should sit just over the threshold, not overshoot to white.
        let sol = solver.solve(text: RGB(hex: 0x3355AA), background: .uniform(RGB(hex: 0x101418)))
        #expect(sol.contrast >= 60 && sol.contrast < 62)
    }

    @Test func midGreyBackgroundPicksCloserPolarity() {
        // Near-white text over mid grey: going lighter (to white) is a far smaller change than going dark.
        let sol = solver.solve(text: RGB(hex: 0xDDDDDD), background: .uniform(RGB(hex: 0x6A6A6A)))
        #expect(sol.polarity == .lighter)
    }

    @Test func impossibleSpreadReportsFailureWithBestEffort() {
        // Background spans black to white within the coverage window: no single text colour works.
        let colours = (0..<100).map { i in RGB(r: Double(i) / 99, g: Double(i) / 99, b: Double(i) / 99) }
        let sol = solver.solve(text: RGB(hex: 0xFF0000), background: BackgroundSample(colors: colours))
        #expect(!sol.meetsTarget)
        #expect(sol.color.isInGamut)
    }

    @Test func hysteresisKeepsPreferredPolarityWhenCostsAreClose() {
        // #A6A6A6 sits where both white and black text clear Lc 45; with matching text, the two
        // directions cost about the same, so the preference should decide.
        let bg = BackgroundSample.uniform(RGB(hex: 0xA6A6A6))
        let wide = ContrastSolver(target: .apca(45), polarityHysteresis: 1.0)
        let a = wide.solve(text: RGB(hex: 0xA7A7A7), background: bg, preferred: .lighter)
        let b = wide.solve(text: RGB(hex: 0xA7A7A7), background: bg, preferred: .darker)
        #expect(a.meetsTarget && b.meetsTarget)
        #expect(a.polarity == .lighter && b.polarity == .darker)
    }

    @Test func wcagTargetIsHonoured() {
        let s = ContrastSolver(target: .wcag(4.5))
        let sol = s.solve(text: RGB(hex: 0x66AA66), background: .uniform(RGB(hex: 0xFFFFFF)))
        #expect(sol.meetsTarget)
        #expect(WCAG.contrastRatio(sol.color, RGB(hex: 0xFFFFFF)) >= 4.5)
    }

    // Property: whenever the solver claims success, every background sample inside the coverage
    // window meets the target; when it claims failure, neither white nor black would have met it.
    @Test(arguments: [ContrastTarget.apca(45), .apca(60), .apca(75), .wcag(3), .wcag(4.5), .wcag(7)])
    func propertyClaimsAreTrue(target: ContrastTarget) {
        var rng = SplitMix64(seed: 42)
        let s = ContrastSolver(target: target, coverage: 1)
        for _ in 0..<400 {
            let text = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            let base = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            let spread = rng.unit() * 0.25
            let colours = (0..<12).map { _ in
                RGB(
                    r: clamp01(base.r + (rng.unit() - 0.5) * spread),
                    g: clamp01(base.g + (rng.unit() - 0.5) * spread),
                    b: clamp01(base.b + (rng.unit() - 0.5) * spread))
            }
            let sol = s.solve(text: text, background: BackgroundSample(colors: colours))
            #expect(sol.color.isInGamut)
            let worst = colours.map { target.score(text: sol.color, background: $0) }.min()!
            if sol.meetsTarget {
                #expect(worst >= target.threshold - 1e-9, "claimed success but worst=\(worst)")
            } else {
                let white = colours.map { target.score(text: RGB(hex: 0xFFFFFF), background: $0) }.min()!
                let black = colours.map { target.score(text: RGB(hex: 0x000000), background: $0) }.min()!
                #expect(max(white, black) < target.threshold + 1e-9)
            }
        }
    }

    @Test func propertyHueIsPreservedUnlessShiftIsChosen() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<300 {
            let text = OKLCH(L: 0.3 + rng.unit() * 0.4, C: 0.12, h: rng.unit() * 360).gamutMapped().rgb
            let bg = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            let sol = solver.solve(text: text, background: .uniform(bg))
            let out = sol.color.oklch
            guard sol.changed && out.C > 0.03 else { continue }
            if sol.hueShifted {
                #expect(hueDistance(out.h, text.oklch.h) <= solver.hueShift.maxHueShift + 0.5)
            } else {
                #expect(hueDistance(out.h, text.oklch.h) < 2.0)
            }
        }
    }
}
