import Testing

@testable import GlassContrast

@Suite("Critically damped spring")
struct SpringTests {
    @Test func convergesToTarget() {
        var s = SpringSmoother(initial: OKLab(L: 0, a: 0, b: 0), omega: 12)
        let target = OKLab(L: 1, a: 0.1, b: -0.1)
        for _ in 0..<120 { _ = s.step(toward: target, dt: 1.0 / 60) }
        #expect(s.position.distance(to: target) < 1e-4)
    }

    @Test func doesNotOvershootFromRest() {
        var s = SpringSmoother(initial: OKLab(L: 0.2, a: 0, b: 0), omega: 12)
        let target = OKLab(L: 0.9, a: 0, b: 0)
        var last = 0.2
        for _ in 0..<300 {
            let p = s.step(toward: target, dt: 1.0 / 60)
            #expect(p.L <= 0.9 + 1e-12)
            #expect(p.L >= last - 1e-12)
            last = p.L
        }
    }

    @Test func isGradualNotInstant() {
        var s = SpringSmoother(initial: OKLab(L: 0, a: 0, b: 0), omega: 12)
        let p = s.step(toward: OKLab(L: 1, a: 0, b: 0), dt: 1.0 / 60)
        #expect(p.L > 0 && p.L < 0.1)
    }

    @Test func frameRateIndependent() {
        // The closed-form step means 60 small steps and 6 big steps land in the same place.
        var fine = SpringSmoother(initial: OKLab(L: 0, a: 0, b: 0), omega: 8)
        var coarse = fine
        let t = OKLab(L: 1, a: 0, b: 0)
        for _ in 0..<60 { _ = fine.step(toward: t, dt: 1.0 / 60) }
        for _ in 0..<6 { _ = coarse.step(toward: t, dt: 1.0 / 6) }
        #expect(abs(fine.position.L - coarse.position.L) < 1e-9)
    }

    @Test func hugeTimestepIsStable() {
        var s = SpringSmoother(initial: OKLab(L: 0, a: 0, b: 0), omega: 12)
        let p = s.step(toward: OKLab(L: 1, a: 0, b: 0), dt: 10)
        #expect(p.L.isFinite && abs(p.L - 1) < 1e-6)
    }
}

@Suite("Adaptive text colour (solver + smoothing)")
struct AdaptiveTests {
    @Test func settlesOnAReadableTargetWithHeadroom() {
        var a = AdaptiveTextColor(original: RGB(hex: 0x3355AA), solver: ContrastSolver(target: .apca(60)))
        let bg = BackgroundSample.uniform(RGB(hex: 0x101418))
        var out = RGB(hex: 0)
        for _ in 0..<180 { out = a.update(background: bg, dt: 1.0 / 60) }
        #expect(out.oklab.distance(to: a.target.oklab) < 1e-3)
        let lc = ContrastTarget.apca(60).score(text: a.target, background: RGB(hex: 0x101418))
        #expect(lc >= 63 - 1e-6 && lc < 65)
    }

    @Test func fallsBackToBareThresholdWhenHeadroomIsImpossible() {
        // 21:1 is only reachable exactly (black on white); 5% headroom would be unreachable.
        var a = AdaptiveTextColor(original: RGB(hex: 0x777777), solver: ContrastSolver(target: .wcag(20)))
        for _ in 0..<240 { _ = a.update(background: .uniform(RGB(hex: 0xFFFFFF)), dt: 1.0 / 60) }
        #expect(ContrastTarget.wcag(20).isMet(text: a.target, background: RGB(hex: 0xFFFFFF)))
    }

    @Test func deadbandIgnoresSensorNoise() {
        var a = AdaptiveTextColor(original: RGB(hex: 0x3355AA), solver: ContrastSolver(target: .apca(60)))
        var rng = SplitMix64(seed: 3)
        for _ in 0..<120 { _ = a.update(background: .uniform(RGB(hex: 0x101418)), dt: 1.0 / 60) }
        let settled = a.target
        var retargets = 0
        for _ in 0..<600 {
            let n = (rng.unit() - 0.5) * 0.01
            let bg = RGB(r: 0x10 / 255.0 + n, g: 0x14 / 255.0 + n, b: 0x18 / 255.0 + n)
            _ = a.update(background: .uniform(bg), dt: 1.0 / 60)
            if a.target != settled { retargets += 1 }
        }
        #expect(retargets == 0)
    }

    @Test func respondsToRealBackgroundChange() {
        var a = AdaptiveTextColor(original: RGB(hex: 0x3355AA), solver: ContrastSolver(target: .apca(60)))
        for _ in 0..<120 { _ = a.update(background: .uniform(RGB(hex: 0x101418)), dt: 1.0 / 60) }
        #expect(a.polarity == .lighter)
        for _ in 0..<240 { _ = a.update(background: .uniform(RGB(hex: 0xF4F4F4)), dt: 1.0 / 60) }
        #expect(a.polarity == .darker)
        #expect(ContrastTarget.apca(60).isMet(text: a.current, background: RGB(hex: 0xF4F4F4)))
    }

    @Test func outputAlwaysInGamut() {
        var a = AdaptiveTextColor(original: RGB(hex: 0xFF00FF), solver: ContrastSolver(target: .apca(75)))
        var rng = SplitMix64(seed: 9)
        for _ in 0..<600 {
            let bg = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            #expect(a.update(background: .uniform(bg), dt: 1.0 / 30).isInGamut)
        }
    }
}
