import CoreGraphics
import CoreImage
import CoreVideo
import GlassContrast
import Testing

@testable import GlassOverlay

@Suite("Display gamut detection and wide-gamut output")
struct DisplayGamutOverlayTests {
    @Test func detectsGamutFromTheDisplayColourSpace() {
        #expect(ColorGamut.of(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) == .sRGB)
        #expect(ColorGamut.of(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) == .displayP3)
        #expect(ColorGamut.of(colorSpace: nil) == .sRGB)
        #expect(ColorGamut.displayP3.cgColorSpace.name == CGColorSpace.displayP3)
        #expect(ColorGamut.sRGB.cgColorSpace.name == CGColorSpace.sRGB)
    }

    @Test func displayInfoDefaultsToSRGB() {
        #expect(DisplayInfo(id: 1, frame: .zero, scale: 2).gamut == .sRGB)
    }

    @Test func textLayerResolvesIntoTheNewGamutWhenTheWindowChangesDisplay() {
        // Saturated green ink over light glass: on P3 the solver keeps chroma sRGB can't hold.
        var model = TextLayerModel(
            target: .apca(60),
            parameters: GlassParameters(mode: .keyed(key: .white, tolerance: 0.05, softness: 0.05, contentAlpha: 1)))
        model.gamut = .displayP3
        let window = frame(
            80, 30, fill: .white, rects: [(CGRect(x: 4, y: 8, width: 20, height: 12), RGB(hex: 0x00AA55))])
        let backdrop = frame(80, 30, fill: RGB(hex: 0xEEEEEE))
        let region = [CGRect(x: 0, y: 4, width: 40, height: 20)]
        var styles: [TextStyle] = []
        for _ in 0..<60 { styles = model.update(regions: region, window: window, backdrop: backdrop, dt: 1.0 / 30) }
        #expect(styles.count == 1)
        #expect(ColorGamut.displayP3.contains(styles[0].color) && !ColorGamut.sRGB.contains(styles[0].color))

        model.gamut = .sRGB
        for _ in 0..<60 {
            styles = model.update(regions: region, window: window, backdrop: backdrop, dt: 1.0 / 30)
            #expect(ColorGamut.sRGB.contains(styles[0].color))
        }
        let bg = model.parameters.effectiveBackground(backdrop: RGB(hex: 0xEEEEEE), windowBackground: .white)
        #expect(ContrastTarget.apca(60).isMet(text: styles[0].color, background: bg))
    }

    @Test func liveBufferIsTaggedWithTheDisplayGamut() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        let out = try #require(buffer)
        let compositor = GlassCompositor(softwareRendering: true)
        let image = compositor.constant(RGB(r: -0.2, g: 0.7, b: 0.3), alpha: 1, CGRect(x: 0, y: 0, width: 4, height: 4))
        for gamut in ColorGamut.allCases {
            compositor.render(image, into: out, gamut: gamut)
            let tag = CVBufferCopyAttachment(out, kCVImageBufferCGColorSpaceKey, nil)
            #expect((tag as! CGColorSpace).name == gamut.cgColorSpace.name)
        }
    }
}
