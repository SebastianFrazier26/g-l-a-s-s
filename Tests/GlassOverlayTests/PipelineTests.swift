import AppKit
import CoreVideo
import GlassContrast
import Testing

@testable import GlassOverlay

/// BGRA, IOSurface-backed, like ScreenCaptureKit delivers; drawn with Core Graphics (top-left up).
func captureBuffer(width: Int, height: Int, draw: (CGContext) -> Void) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(pb!), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    draw(ctx)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

@Suite("Overlay pipeline (synthetic capture buffers)")
struct PipelineTests {
    func fill(_ c: CGColor) -> (CGContext) -> Void {
        { ctx in
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        }
    }

    @Test func compositesWindowOverBackdrop() throws {
        var p = GlassParameters(mode: .uniform(alpha: 0.5))
        p.tintOpacity = 0
        let pipe = OverlayPipeline(options: .init(parameters: p), softwareRendering: true)
        #expect(pipe.ingestWindow(captureBuffer(width: 32, height: 32, draw: fill(.white))) == nil)  // no backdrop yet
        pipe.ingestBackdrop(captureBuffer(width: 16, height: 16, draw: fill(.black)))  // half-res backdrop
        let out = try #require(pipe.ingestWindow(captureBuffer(width: 32, height: 32, draw: fill(.white))))
        let img = try #require(RGBAImage(bgra: out))
        #expect(img.width == 32 && abs(Int(img.pixel(16, 16).g) - 188) <= 3)
    }

    @Test func analysisFindsAndStylesText() async throws {
        let p = GlassParameters(mode: .keyed(key: .white, tolerance: 0.05, softness: 0.05, contentAlpha: 1))
        let pipe = OverlayPipeline(options: .init(parameters: p), softwareRendering: true)
        pipe.ingestBackdrop(captureBuffer(width: 240, height: 60, draw: fill(CGColor(gray: 0.02, alpha: 1))))
        _ = pipe.ingestWindow(
            captureBuffer(width: 480, height: 120) { ctx in
                ctx.setFillColor(.white)
                ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 120))
                let s = NSAttributedString(
                    string: "GLASS CONTRAST",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.systemBlue])
                ctx.textPosition = CGPoint(x: 20, y: 40)
                CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
            })
        for i in 0..<10 { await pipe.analyse(runOCR: i == 0, dt: 0.1, scale: 0.5) }
        let styles = pipe.currentStyles
        #expect(!styles.isEmpty)
        // Blue text over near-black glass must have been made readable against the tinted glass.
        if let s = styles.first {
            let gray = 0.02
            let behind = p.effectiveBackground(backdrop: RGB(r: gray, g: gray, b: gray), windowBackground: .white)
            #expect(ContrastTarget.apca(57).isMet(text: s.color, background: behind))
            #expect(s.rect.width > 100)  // rect mapped back to full-resolution coordinates
        }
    }
}

@Suite("Overlay pipeline geometry and pausing")
struct PipelineGeometryTests {
    func solid(_ c: CGColor, _ w: Int, _ h: Int) -> CVPixelBuffer {
        captureBuffer(width: w, height: h) { ctx in
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    @Test func holesReachTheOutput() throws {
        var p = GlassParameters(mode: .uniform(alpha: 1))
        p.tintOpacity = 0
        let pipe = OverlayPipeline(options: .init(parameters: p), softwareRendering: true)
        pipe.ingestBackdrop(solid(.black, 20, 20))
        pipe.setGeometry(holes: [CGRect(x: 0, y: 0, width: 20, height: 40)], backdropCoverage: nil)
        let out = try #require(pipe.ingestWindow(solid(.white, 40, 40)))
        let img = try #require(RGBAImage(bgra: out))
        #expect(img.pixel(5, 20).a == 0 && img.pixel(30, 20).a == 255)
    }

    @Test func pausedSkipsCompositing() {
        let pipe = OverlayPipeline(
            options: .init(parameters: GlassParameters(mode: .uniform(alpha: 1))), softwareRendering: true)
        pipe.ingestBackdrop(solid(.black, 20, 20))
        pipe.setPaused(true)
        #expect(pipe.ingestWindow(solid(.white, 40, 40)) == nil)
        pipe.setPaused(false)
        #expect(pipe.ingestWindow(solid(.white, 40, 40)) != nil)
    }
}
