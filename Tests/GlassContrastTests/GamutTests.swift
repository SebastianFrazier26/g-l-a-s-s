import Testing

@testable import GlassContrast

@Suite("Display gamuts (sRGB and Display P3)")
struct DisplayGamutTests {
    @Test func matricesAreInversesAndKeepWhite() {
        var rng = SplitMix64(seed: 11)
        for _ in 0..<200 {
            let c = LinearRGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            let back = ColorGamut.fromP3(ColorGamut.toP3(c))
            #expect(abs(back.r - c.r) < 1e-9 && abs(back.g - c.g) < 1e-9 && abs(back.b - c.b) < 1e-9)
        }
        let w = ColorGamut.toP3(LinearRGB(r: 1, g: 1, b: 1))
        #expect(abs(w.r - 1) < 1e-9 && abs(w.g - 1) < 1e-9 && abs(w.b - 1) < 1e-9)
    }

    @Test func p3ContainsSRGBButNotViceVersa() {
        var rng = SplitMix64(seed: 12)
        for _ in 0..<200 {
            #expect(ColorGamut.displayP3.contains(RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())))
        }
        let p3Red = ColorGamut.fromP3(LinearRGB(r: 1, g: 0, b: 0)).encoded
        #expect(ColorGamut.displayP3.contains(p3Red))
        #expect(!ColorGamut.sRGB.contains(p3Red))
        #expect(p3Red.r > 1)
    }

    @Test func clampLandsInsideEachGamut() {
        let wild = RGB(r: 1.4, g: -0.3, b: 0.5)
        for g in ColorGamut.allCases { #expect(g.contains(g.clamp(wild))) }
        let inP3 = ColorGamut.fromP3(LinearRGB(r: 0.9, g: 0.1, b: 0.1)).encoded
        #expect(ColorGamut.displayP3.clamp(inP3) == inP3)
    }

    @Test func p3HasAtLeastSRGBChromaEverywhere() {
        for L in stride(from: 0.1, through: 0.95, by: 0.05) {
            for h in stride(from: 0.0, to: 360, by: 15) {
                let s = Gamut.maxChroma(lightness: L, hue: h, in: .sRGB)
                let p = Gamut.maxChroma(lightness: L, hue: h, in: .displayP3)
                #expect(p >= s - 1e-6)
            }
        }
        // Greens are where P3 gains most.
        #expect(
            Gamut.maxChroma(lightness: 0.8, hue: 145, in: .displayP3) > 1.15 * Gamut.maxChroma(lightness: 0.8, hue: 145)
        )
    }

    @Test func luminanceIsContinuousAcrossTheSRGBBoundary() {
        // Extended values are scored, not clipped: a P3 colour just past the sRGB edge scores like its neighbour.
        let edge = RGB(r: 0, g: 0.6, b: 0.3), past = RGB(r: -0.01, g: 0.6, b: 0.3)
        #expect(abs(APCA.screenLuminance(edge) - APCA.screenLuminance(past)) < 1e-3)
        #expect(APCA.screenLuminance(past) != APCA.screenLuminance(edge))
        #expect(abs(WCAG.relativeLuminance(edge) - WCAG.relativeLuminance(past)) < 1e-3)
    }

    @Test func solverUsesP3RoomOnP3Displays() {
        // Saturated green on white: sRGB has to drop chroma to darken it; P3 keeps all of it.
        let text = RGB(hex: 0x00AA55), bg = BackgroundSample.uniform(RGB(hex: 0xEEEEEE))
        let srgb = ContrastSolver(target: .apca(60), gamut: .sRGB).solve(text: text, background: bg)
        let p3 = ContrastSolver(target: .apca(60), gamut: .displayP3).solve(text: text, background: bg)
        #expect(srgb.meetsTarget && p3.meetsTarget)
        #expect(ColorGamut.sRGB.contains(srgb.color))
        #expect(ColorGamut.displayP3.contains(p3.color) && !ColorGamut.sRGB.contains(p3.color))
        #expect(p3.color.oklch.C > srgb.color.oklch.C + 0.01)
        #expect(APCA.lightnessContrast(text: p3.color, background: RGB(hex: 0xEEEEEE)).magnitude >= 60 - 1e-9)
    }

    @Test(arguments: ColorGamut.allCases)
    func propertyResultsStayInTheTargetGamut(gamut: ColorGamut) {
        var rng = SplitMix64(seed: 21)
        let s = ContrastSolver(target: .apca(60), coverage: 1, gamut: gamut)
        for _ in 0..<200 {
            let text = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            let bg = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            let sol = s.solve(text: text, background: .uniform(bg))
            #expect(gamut.contains(sol.color))
            if sol.meetsTarget { #expect(ContrastTarget.apca(60).score(text: sol.color, background: bg) >= 60 - 1e-9) }
        }
    }

    @Test func movingToAnSRGBDisplayResolvesIntoSRGB() {
        let text = RGB(hex: 0x00AA55), bg = BackgroundSample.uniform(RGB(hex: 0xEEEEEE))
        var a = AdaptiveTextColor(original: text, solver: ContrastSolver(target: .apca(60), gamut: .displayP3))
        for _ in 0..<60 { _ = a.update(background: bg, dt: 1.0 / 60) }
        #expect(!ColorGamut.sRGB.contains(a.target))
        a.setGamut(.sRGB)
        #expect(ColorGamut.sRGB.contains(a.target))
        for _ in 0..<60 {
            _ = a.update(background: bg, dt: 1.0 / 60)
            #expect(ColorGamut.sRGB.contains(a.current))
        }
        #expect(ColorGamut.sRGB.contains(a.target))
        #expect(ContrastTarget.apca(60).score(text: a.target, background: RGB(hex: 0xEEEEEE)) >= 60)
    }
}
