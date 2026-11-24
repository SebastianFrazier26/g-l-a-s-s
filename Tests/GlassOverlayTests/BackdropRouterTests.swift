import CoreGraphics
import CoreImage
import GlassContrast
import Testing

@testable import GlassOverlay

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [CIImage] = []
    func add(_ i: CIImage) { lock.withLock { images.append(i) } }
    var all: [CIImage] { lock.withLock { images } }
}

@Suite("Backdrop router: one display capture, many windows")
struct BackdropRouterTests {
    let compositor = GlassCompositor(softwareRendering: true)
    // Display 400×200 pt captured at half of 2× = 400×200 px. Left half black, right half white,
    // a red block at top-left (top-left coordinates).
    var displayFrame: CIImage {
        frame(
            400, 200, fill: .black,
            rects: [
                (CGRect(x: 200, y: 0, width: 200, height: 200), .white),
                (CGRect(x: 0, y: 0, width: 50, height: 50), RGB(r: 1, g: 0, b: 0)),
            ]
        ).ciImage
    }
    let size = CGSize(width: 400, height: 200)

    @Test func cropIsTheWindowsPartInTopLeftCoordinatesAtTheOrigin() {
        let route = BackdropRouter.Route(
            display: 1, sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100), displaySize: size)
        let c = BackdropRouter.crop(displayFrame, route: route)
        #expect(c.extent == CGRect(x: 0, y: 0, width: 100, height: 100))
        let img = compositor.renderRGBA(c, width: 100, height: 100)!
        #expect(img.pixel(10, 10).r == 255 && img.pixel(10, 10).g == 0)  // red block is top-left
        #expect(img.pixel(80, 80).r == 0)
    }

    @Test func scalesPointsToFramePixels() {
        // Same display captured at 200×100 px (a quarter of 2×): a 100 pt window is 50 px.
        let small = displayFrame.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let route = BackdropRouter.Route(
            display: 1, sourceRect: CGRect(x: 250, y: 50, width: 100, height: 100), displaySize: size)
        let c = BackdropRouter.crop(small, route: route)
        #expect(c.extent.size == CGSize(width: 50, height: 50))
        #expect(compositor.renderRGBA(c, width: 50, height: 50)!.pixel(25, 25).r == 255)  // white half
    }

    @Test func deliversOnlyToWindowsOnThatDisplayUnderADirtyRect() {
        let router = BackdropRouter()
        let a = Received(), b = Received(), other = Received()
        router.set(
            1, route: .init(display: 7, sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100), displaySize: size),
            sink: a.add)
        router.set(
            2, route: .init(display: 7, sourceRect: CGRect(x: 300, y: 100, width: 100, height: 100), displaySize: size),
            sink: b.add)
        router.set(
            3, route: .init(display: 8, sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100), displaySize: size),
            sink: other.add)

        let elsewhere = [CGRect(x: 10, y: 10, width: 5, height: 5)]
        router.deliver(displayFrame, display: 7, dirtyRects: elsewhere)  // first frame: everyone is fed
        #expect(a.all.count == 1 && b.all.count == 1 && other.all.isEmpty)
        router.deliver(displayFrame, display: 7, dirtyRects: [])  // empty: unknown, everyone
        #expect(a.all.count == 2 && b.all.count == 2)
        router.deliver(displayFrame, display: 7, dirtyRects: nil)  // unknown: everyone on display 7
        #expect(a.all.count == 3 && b.all.count == 3 && other.all.isEmpty)

        router.deliver(displayFrame, display: 7, dirtyRects: elsewhere)
        #expect(a.all.count == 4 && b.all.count == 3)
        #expect(router.takeSkipped(2) == 1 && router.takeSkipped(2) == 0)

        router.update(2, route: .init(display: 8, sourceRect: .zero, displaySize: size))
        #expect(router.displaysInUse == [8, 7])
        router.remove(1)
        #expect(router.displaysInUse == [8])
    }

    @Test func pipelineAcceptsARoutedBackdrop() throws {
        var p = GlassParameters(mode: .uniform(alpha: 0))
        p.tintOpacity = 0
        p.blurRadius = 0
        let pipe = OverlayPipeline(options: .init(parameters: p), softwareRendering: true)
        pipe.ingestWindow(captureBuffer(width: 200, height: 200) { _ in })
        let route = BackdropRouter.Route(
            display: 1, sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100), displaySize: size)
        let out = try #require(pipe.ingestBackdrop(image: BackdropRouter.crop(displayFrame, route: route)))
        let img = try #require(RGBAImage(bgra: out))
        #expect(img.pixel(10, 10).r > 245 && img.pixel(10, 10).g < 10)  // red, scaled 2× up, still top-left
        #expect(img.pixel(150, 150).r < 10)
    }
}
