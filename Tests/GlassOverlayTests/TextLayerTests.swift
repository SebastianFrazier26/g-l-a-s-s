import AppKit
import CoreGraphics
import GlassContrast
import Testing

@testable import GlassOverlay

@Suite("Text region analysis")
struct TextRegionAnalysisTests {
    let window = frame(
        60, 30, fill: RGB(hex: 0xF5F5F5),
        rects: [
            (CGRect(x: 5, y: 10, width: 3, height: 10), RGB(hex: 0x2D5BD8)),
            (CGRect(x: 12, y: 10, width: 3, height: 10), RGB(hex: 0x2D5BD8)),
        ])

    @Test func dominantColourIsTheWindowBackground() {
        let c = TextRegionAnalysis.dominantColor(in: window, rect: CGRect(x: 0, y: 0, width: 30, height: 30))
        #expect(c.oklab.distance(to: RGB(hex: 0xF5F5F5).oklab) < 0.02)
    }

    @Test func textColourIsTheNonBackgroundInk() {
        let c = TextRegionAnalysis.textColor(
            in: window, rect: CGRect(x: 0, y: 0, width: 30, height: 30), background: RGB(hex: 0xF5F5F5))
        #expect(c != nil)
        #expect(c!.oklab.distance(to: RGB(hex: 0x2D5BD8).oklab) < 0.03)
    }

    @Test func plainRegionHasNoText() {
        let c = TextRegionAnalysis.textColor(
            in: window, rect: CGRect(x: 30, y: 0, width: 30, height: 30), background: RGB(hex: 0xF5F5F5))
        #expect(c == nil)
    }

    @Test func textLikeVersusPhoto() {
        #expect(TextRegionAnalysis.isLikelyText(in: window, rect: CGRect(x: 0, y: 0, width: 30, height: 30)))
        var rng = SplitMix64(seed: 5)
        let noise = RGBAImage(width: 30, height: 30, data: (0..<(30 * 30 * 4)).map { _ in UInt8(rng.next() & 0xFF) })
        #expect(!TextRegionAnalysis.isLikelyText(in: noise, rect: CGRect(x: 0, y: 0, width: 30, height: 30)))
    }
}

@Suite("Region matching across OCR refreshes")
struct RegionMatchingTests {
    @Test func keepsIdentityForOverlappingBoxes() {
        let old = [
            TrackedRegion(id: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 20)),
            TrackedRegion(id: 2, rect: CGRect(x: 0, y: 40, width: 100, height: 20)),
        ]
        var next = 3
        let new = RegionMatcher.match(
            previous: old,
            detected: [CGRect(x: 2, y: 41, width: 100, height: 20), CGRect(x: 0, y: 100, width: 50, height: 20)],
            nextID: &next)
        #expect(new.map(\.id) == [2, 3])
        #expect(next == 4)
    }

    @Test func iou() {
        #expect(
            RegionMatcher.iou(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: 10)) == 1
        )
        #expect(
            RegionMatcher.iou(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 0, width: 10, height: 10))
                == 0)
    }
}

@Suite("Text layer model")
struct TextLayerModelTests {
    @Test func producesReadableStylesOverDarkGlass() {
        var model = TextLayerModel(
            target: .apca(60),
            parameters: GlassParameters(mode: .keyed(key: .white, tolerance: 0.05, softness: 0.05, contentAlpha: 1)))
        let window = frame(
            80, 30, fill: .white, rects: [(CGRect(x: 4, y: 8, width: 20, height: 12), RGB(hex: 0x2D5BD8))])
        let backdrop = frame(80, 30, fill: RGB(hex: 0x050608))
        var styles: [TextStyle] = []
        for _ in 0..<120 {
            styles = model.update(
                regions: [CGRect(x: 0, y: 4, width: 40, height: 20)], window: window, backdrop: backdrop, dt: 1.0 / 30)
        }
        #expect(styles.count == 1)
        let bg = model.parameters.effectiveBackground(backdrop: RGB(hex: 0x050608), windowBackground: .white)
        #expect(ContrastTarget.apca(60).isMet(text: styles[0].color, background: bg))
        #expect(styles[0].regionBackground.oklab.distance(to: RGB.white.oklab) < 0.02)
    }

    @Test func dropsRegionsWithoutInk() {
        var model = TextLayerModel(target: .apca(60), parameters: GlassParameters(mode: .uniform(alpha: 0.5)))
        let styles = model.update(
            regions: [CGRect(x: 0, y: 0, width: 20, height: 20)], window: frame(40, 40, fill: .white),
            backdrop: frame(40, 40, fill: .black), dt: 1.0 / 30)
        #expect(styles.isEmpty)
    }

    @Test func urgentFlagIsPassedThrough() {
        let model = TextLayerModel(
            target: .apca(60), parameters: GlassParameters(mode: .uniform(alpha: 0.5)), urgentOmega: 40)
        #expect(model.urgentOmega == 40)
    }
}

@Suite("Vision text detection (offline, synthetic image)")
struct VisionDetectorTests {
    @Test func findsRenderedText() async throws {
        let img = try #require(renderText("GLASS CONTRAST", size: CGSize(width: 480, height: 120)))
        let boxes = try await VisionTextDetector().detect(in: img)
        #expect(!boxes.isEmpty)
        // Boxes come back in top-left pixel coordinates inside the image.
        for b in boxes { #expect(b.minX >= 0 && b.minY >= 0 && b.maxX <= 480.5 && b.maxY <= 120.5) }
    }

    func renderText(_ s: String, size: CGSize) -> CGImage? {
        guard
            let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let attr = NSAttributedString(
            string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 20, y: 40)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}
