import Testing

@testable import GlassContrast

@Suite("Scrim fallback")
struct ScrimTests {
    let solver = ContrastSolver(target: .apca(60), coverage: 1)
    let blackToWhite = BackgroundSample(
        colors: (0..<50).map { i in RGB(r: Double(i) / 49, g: Double(i) / 49, b: Double(i) / 49) })

    @Test func noScrimWhenTextAloneWorks() {
        let r = solver.solveWithScrim(text: RGB(hex: 0x3355AA), background: .uniform(RGB(hex: 0x101418)))
        #expect(r.opacity == 0 && r.solution.meetsTarget)
    }

    @Test func scrimRescuesImpossibleSpread() {
        #expect(!solver.solve(text: RGB(hex: 0xFF0000), background: blackToWhite).meetsTarget)
        let r = solver.solveWithScrim(text: RGB(hex: 0xFF0000), background: blackToWhite)
        #expect(r.solution.meetsTarget)
        #expect(r.opacity > 0 && r.opacity < 0.85)
        let veiled = blackToWhite.colors.map { r.apply(to: $0) }
        let worst = veiled.map { ContrastTarget.apca(60).score(text: r.solution.color, background: $0) }.min()!
        #expect(worst >= 60 - 1e-9)
    }

    @Test func scrimColourOpposesTextPolarity() {
        let r = solver.solveWithScrim(text: RGB(hex: 0xFF0000), background: blackToWhite)
        if r.solution.polarity == .lighter {
            #expect(r.scrim == RGB(hex: 0x000000))
        } else {
            #expect(r.scrim == RGB(hex: 0xFFFFFF))
        }
    }

    @Test func opacityIsMinimal() {
        let r = solver.solveWithScrim(text: RGB(hex: 0xFF0000), background: blackToWhite)
        let less = BackgroundSample(
            colors: blackToWhite.colors.map { c in
                ScrimResult.blend(c, over: r.scrim, opacity: r.opacity - 0.02)
            })
        let s = solver.solve(text: RGB(hex: 0xFF0000), background: less, preferred: r.solution.polarity)
        #expect(!(s.meetsTarget && s.polarity == r.solution.polarity))
    }

    @Test func capsAtMaxOpacity() {
        let r = solver.solveWithScrim(
            text: RGB(hex: 0xFF0000), background: blackToWhite, maxOpacity: 0.05)
        #expect(r.opacity <= 0.05 + 1e-12)
        #expect(!r.solution.meetsTarget)
    }
}

@Suite("Adaptive text colour with scrim")
struct AdaptiveScrimTests {
    @Test func scrimFadesInThenOut() {
        var a = AdaptiveTextColor(
            original: RGB(hex: 0xFF0000), solver: ContrastSolver(target: .apca(60)), allowScrim: true)
        let spread = BackgroundSample(
            colors: (0..<50).map { i in RGB(r: Double(i) / 49, g: Double(i) / 49, b: Double(i) / 49) })
        for _ in 0..<240 { _ = a.update(background: spread, dt: 1.0 / 60) }
        #expect(a.scrimOpacity > 0.1)
        for _ in 0..<240 { _ = a.update(background: .uniform(RGB(hex: 0x101010)), dt: 1.0 / 60) }
        #expect(a.scrimOpacity < 0.01)
    }

    @Test func scrimNeverUsedWhenDisabled() {
        var a = AdaptiveTextColor(original: RGB(hex: 0xFF0000), solver: ContrastSolver(target: .apca(60)))
        let spread = BackgroundSample(
            colors: (0..<50).map { i in RGB(r: Double(i) / 49, g: Double(i) / 49, b: Double(i) / 49) })
        for _ in 0..<120 { _ = a.update(background: spread, dt: 1.0 / 60) }
        #expect(a.scrimOpacity == 0)
    }
}
