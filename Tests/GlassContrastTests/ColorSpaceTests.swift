import Testing

@testable import GlassContrast

private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-4) -> Bool { abs(a - b) <= tol }

@Suite("sRGB transfer function")
struct TransferTests {
    @Test func endpoints() {
        #expect(srgbToLinear(0) == 0)
        #expect(close(srgbToLinear(1), 1, 1e-12))
        #expect(close(linearToSRGB(1), 1, 1e-12))
    }

    @Test func linearSegmentBelowThreshold() {
        #expect(close(srgbToLinear(0.04), 0.04 / 12.92, 1e-12))
    }

    @Test func knownMidGrey() {
        // sRGB 0.5 decodes to 0.21404 (IEC 61966-2-1 curve).
        #expect(close(srgbToLinear(0.5), 0.214041, 1e-6))
        #expect(close(linearToSRGB(0.214041), 0.5, 1e-6))
    }

    @Test func roundTripAcrossRange() {
        for i in 0...1000 {
            let v = Double(i) / 1000
            #expect(close(linearToSRGB(srgbToLinear(v)), v, 1e-12))
        }
    }
}

@Suite("OKLab / OKLCH reference values")
struct OKLabReferenceTests {
    // Reference values: Björn Ottosson's published matrices, as used by CSS Color 4.
    @Test func white() {
        let lab = RGB(hex: 0xFFFFFF).oklab
        #expect(close(lab.L, 1.0))
        #expect(close(lab.a, 0))
        #expect(close(lab.b, 0))
    }

    @Test func black() {
        let lab = RGB(hex: 0x000000).oklab
        #expect(close(lab.L, 0) && close(lab.a, 0) && close(lab.b, 0))
    }

    @Test(arguments: [
        (0xFF0000 as UInt32, 0.627955, 0.224863, 0.125846),
        (0x00FF00, 0.866440, -0.233888, 0.179498),
        (0x0000FF, 0.452014, -0.032457, -0.311528),
    ])
    func primaries(hex: UInt32, L: Double, a: Double, b: Double) {
        let lab = RGB(hex: hex).oklab
        #expect(close(lab.L, L, 2e-4))
        #expect(close(lab.a, a, 2e-4))
        #expect(close(lab.b, b, 2e-4))
    }

    @Test func redLCH() {
        let lch = RGB(hex: 0xFF0000).oklch
        #expect(close(lch.L, 0.62796, 2e-4))
        #expect(close(lch.C, 0.25768, 2e-4))
        #expect(close(lch.h, 29.234, 0.01))
    }

    @Test func hueIsNormalisedToZeroThreeSixty() {
        let lch = RGB(hex: 0x0000FF).oklch
        #expect(lch.h >= 0 && lch.h < 360)
        #expect(close(lch.h, 264.05, 0.02))
    }

    @Test func greyHasZeroChroma() {
        #expect(RGB(hex: 0x777777).oklch.C < 1e-6)
    }

    // Ottosson's published forward and inverse matrices are rounded to 10 digits and are not exact
    // inverses of each other; measured worst case is ~1.6e-6, far below one 8-bit step (3.9e-3).
    @Test func roundTripRandomColours() {
        var rng = SplitMix64(seed: 1)
        for _ in 0..<5000 {
            let c = RGB(r: rng.unit(), g: rng.unit(), b: rng.unit())
            let back = c.oklch.rgb
            #expect(close(back.r, c.r, 5e-6) && close(back.g, c.g, 5e-6) && close(back.b, c.b, 5e-6))
        }
    }

    @Test func hexParsing() {
        let c = RGB(hex: 0x336699)
        #expect(close(c.r, 0x33 / 255.0, 1e-12) && close(c.g, 0x66 / 255.0, 1e-12) && close(c.b, 0x99 / 255.0, 1e-12))
    }
}

@Suite("Gamut")
struct GamutTests {
    @Test func maxChromaIsInGamutAndTight() {
        var rng = SplitMix64(seed: 2)
        for _ in 0..<500 {
            let L = rng.unit(), h = rng.unit() * 360
            let c = Gamut.maxChroma(lightness: L, hue: h)
            #expect(OKLCH(L: L, C: c, h: h).isInGamut)
            if L > 0.02 && L < 0.98 {
                #expect(!OKLCH(L: L, C: c + 0.005, h: h).isInGamut)
            }
        }
    }

    @Test func extremesHaveNoChroma() {
        #expect(Gamut.maxChroma(lightness: 1, hue: 120) < 1e-3)
        #expect(Gamut.maxChroma(lightness: 0, hue: 120) < 1e-3)
    }

    @Test func gamutMappingKeepsLightnessAndHue() {
        let wild = OKLCH(L: 0.7, C: 0.4, h: 200)
        let mapped = wild.gamutMapped()
        #expect(mapped.isInGamut)
        #expect(mapped.L == wild.L && mapped.h == wild.h)
        #expect(mapped.C < wild.C)
    }
}
