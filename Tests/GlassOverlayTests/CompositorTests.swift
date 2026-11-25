import CoreGraphics
import CoreImage
import GlassContrast
import Testing

@testable import GlassOverlay

/// Synthetic frames: solid fills plus rectangles, in top-left pixel coordinates like a capture.
func frame(_ w: Int, _ h: Int, fill: RGB, rects: [(CGRect, RGB)] = []) -> RGBAImage {
    var img = RGBAImage(width: w, height: h, fill: fill)
    for (r, c) in rects { img.fill(r, with: c) }
    return img
}

private func near(_ a: UInt8, _ b: Int, _ tol: Int = 3) -> Bool { abs(Int(a) - b) <= tol }

@Suite("Glass compositor (synthetic frames, software Core Image)")
struct CompositorTests {
    let compositor = GlassCompositor(softwareRendering: true)

    func render(_ backdrop: RGBAImage, _ window: RGBAImage, _ p: GlassParameters, text: [TextStyle] = [])
        -> RGBAImage
    {
        let out = compositor.compose(backdrop: backdrop.ciImage, window: window.ciImage, parameters: p, text: text)
        return compositor.renderRGBA(out, width: window.width, height: window.height)!
    }

    @Test func uniformAlphaMixesInLinearLight() {
        var p = GlassParameters(mode: .uniform(alpha: 0.5))
        p.tintOpacity = 0
        let out = render(frame(32, 32, fill: .black), frame(32, 32, fill: .white), p)
        // 50% linear light = 0.5 → sRGB 0.735 → 188.
        let px = out.pixel(16, 16)
        #expect(near(px.r, 188) && near(px.g, 188) && near(px.b, 188))
    }

    @Test func tintIsAppliedOverBackdrop() {
        var p = GlassParameters(mode: .uniform(alpha: 0))
        p.tint = .white
        p.tintOpacity = 0.18
        let out = render(frame(32, 32, fill: .black), frame(32, 32, fill: .black), p)
        // 18% linear white over black → sRGB 0.461 → 118.
        #expect(near(out.pixel(16, 16).g, 118))
    }

    @Test func keyedModeRemovesWindowBackgroundAndKeepsContent() {
        var p = GlassParameters(mode: .keyed(key: .white, tolerance: 0.05, softness: 0.05, contentAlpha: 1))
        p.tintOpacity = 0
        p.blurRadius = 0
        let red = RGB(r: 1, g: 0, b: 0)
        let window = frame(40, 40, fill: .white, rects: [(CGRect(x: 4, y: 4, width: 10, height: 10), .black)])
        let out = render(frame(40, 40, fill: red), window, p)
        let bg = out.pixel(30, 30), glyph = out.pixel(8, 8)
        #expect(near(bg.r, 255) && near(bg.g, 0) && near(bg.b, 0))  // white keyed out → backdrop shows
        #expect(near(glyph.r, 0) && near(glyph.g, 0) && near(glyph.b, 0))  // content kept solid
    }

    /// Owner feedback 2026-11-24: with the default look, backdrop detail must survive the glass.
    /// Checker squares of 48 px (24 pt on Retina, about an icon) keep most of their contrast; the
    /// pre-feedback look (sigma 24, 18% tint) flattened them to a grey wash.
    @Test func defaultLookKeepsBackdropRecognisable() {
        let n = 48
        var backdrop = frame(4 * n, 4 * n, fill: .white)
        for y in stride(from: 0, to: 4 * n, by: n) {
            for x in stride(from: 0, to: 4 * n, by: n) where (x / n + y / n) % 2 == 0 {
                backdrop.fill(CGRect(x: x, y: y, width: n, height: n), with: .black)
            }
        }
        func contrast(_ p: GlassParameters) -> Int {
            let out = render(backdrop, frame(4 * n, 4 * n, fill: .white), p)
            return Int(out.pixel(2 * n + n / 2, n + n / 2).g) - Int(out.pixel(n + n / 2, n + n / 2).g)
        }
        #expect(contrast(OwnerDefaults.look.parameters(for: .keyed, key: .white)) > 180)
        let before = GlassLook(transparency: 0, tintOpacity: 0.18, blurRadius: 24)
        #expect(contrast(before.parameters(for: .keyed, key: .white)) < 120)
    }

    @Test func keyedContentAlphaLetsGlassThroughContent() {
        var p = GlassParameters(mode: .keyed(key: .white, tolerance: 0.05, softness: 0.05, contentAlpha: 0.5))
        p.tintOpacity = 0
        p.blurRadius = 0
        let window = frame(40, 40, fill: .white, rects: [(CGRect(x: 4, y: 4, width: 10, height: 10), .black)])
        let out = render(frame(40, 40, fill: .white), window, p)
        // 50% black content over white glass → 0.5 linear → 188.
        #expect(near(out.pixel(8, 8).r, 188))
    }

    @Test func orientationIsTopLeft() {
        // A black block in the *top-left* of the window must land top-left in the output.
        var p = GlassParameters(mode: .keyed(key: .white, tolerance: 0.05, softness: 0.05, contentAlpha: 1))
        p.tintOpacity = 0
        let window = frame(40, 40, fill: .white, rects: [(CGRect(x: 0, y: 0, width: 10, height: 10), .black)])
        let out = render(frame(40, 40, fill: .white), window, p)
        #expect(near(out.pixel(2, 2).r, 0))
        #expect(near(out.pixel(2, 37).r, 255))
    }

    @Test func blurSoftensBackdropEdgesOnly() {
        var p = GlassParameters(mode: .uniform(alpha: 0))
        p.tintOpacity = 0
        p.blurRadius = 4
        let backdrop = frame(64, 16, fill: .black, rects: [(CGRect(x: 32, y: 0, width: 32, height: 16), .white)])
        let out = render(backdrop, frame(64, 16, fill: .black), p)
        #expect(near(out.pixel(2, 8).r, 0) && near(out.pixel(61, 8).r, 255))
        let edge = Int(out.pixel(32, 8).r)
        #expect(edge > 60 && edge < 230)
    }

    @Test func textStyleRecoloursOnlyGlyphPixelsInsideRegion() {
        var p = GlassParameters(mode: .keyed(key: .white, tolerance: 0.05, softness: 0.05, contentAlpha: 1))
        p.tintOpacity = 0
        let glyph = CGRect(x: 10, y: 10, width: 6, height: 6)
        let outsideGlyph = CGRect(x: 40, y: 10, width: 6, height: 6)
        let window = frame(64, 32, fill: .white, rects: [(glyph, .black), (outsideGlyph, .black)])
        let style = TextStyle(
            rect: CGRect(x: 4, y: 4, width: 24, height: 20), regionBackground: .white,
            color: RGB(r: 0, g: 0, b: 1), scrim: .black, scrimOpacity: 0)
        let out = render(frame(64, 32, fill: .black), window, p, text: [style])
        let a = out.pixel(12, 12), b = out.pixel(42, 12)
        #expect(near(a.b, 255) && near(a.r, 0))  // recoloured to blue
        #expect(near(b.r, 0) && near(b.b, 0))  // outside the region: untouched (black)
    }

    @Test func scrimDarkensRegionBehindText() {
        var p = GlassParameters(mode: .uniform(alpha: 0))
        p.tintOpacity = 0
        let style = TextStyle(
            rect: CGRect(x: 0, y: 0, width: 16, height: 16), regionBackground: .white, color: .white,
            scrim: .black, scrimOpacity: 0.5)
        let out = render(frame(32, 16, fill: .white), frame(32, 16, fill: .white), p, text: [style])
        // 50% linear black over white → 0.5 linear → 188; outside the region stays 255.
        #expect(near(out.pixel(8, 8).r, 188) && near(out.pixel(24, 8).r, 255))
    }
}

@Suite("Effective background behind text")
struct EffectiveBackgroundTests {
    @Test func keyedModeSeesTintedBackdrop() {
        let p = GlassParameters(mode: .keyed(key: .white, tolerance: 0.05, softness: 0.05, contentAlpha: 1))
        let c = p.effectiveBackground(backdrop: .black, windowBackground: .white)
        #expect(abs(c.linear.r - p.tintOpacity) < 1e-9)
    }

    @Test func uniformModeMixesWindowBackgroundIn() {
        var p = GlassParameters(mode: .uniform(alpha: 0.5))
        p.tintOpacity = 0
        let c = p.effectiveBackground(backdrop: .black, windowBackground: .white)
        #expect(abs(c.linear.g - 0.5) < 1e-9)
    }
}
