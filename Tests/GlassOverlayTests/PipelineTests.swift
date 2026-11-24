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

/// Regressions from the first live run (2026-11-23): overlays that never drew, glass that never
/// followed the backdrop, and analysis that re-ran OCR on a static window forever.
@Suite("Overlay pipeline: what triggers a composite, and when analysis idles")
struct PipelineTriggerTests {
    func solid(_ c: CGColor, _ w: Int, _ h: Int) -> CVPixelBuffer {
        captureBuffer(width: w, height: h) { ctx in
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    func uniformPipe() -> OverlayPipeline {
        var p = GlassParameters(mode: .uniform(alpha: 0))
        p.tintOpacity = 0
        p.blurRadius = 0
        return OverlayPipeline(options: .init(parameters: p), softwareRendering: true)
    }

    @Test func windowFrameBeforeFirstBackdropStillGetsDrawn() throws {
        let pipe = uniformPipe()
        #expect(pipe.ingestWindow(solid(.white, 40, 40)) == nil)
        // A static window sends no second frame; the backdrop's first frame must draw it.
        let out = try #require(pipe.ingestBackdrop(solid(.black, 20, 20)))
        #expect(RGBAImage(bgra: out)?.width == 40)
    }

    @Test func backdropChangeReachesTheGlassWithoutANewWindowFrame() throws {
        let pipe = uniformPipe()
        pipe.ingestWindow(solid(.white, 40, 40))
        pipe.ingestBackdrop(solid(.black, 20, 20))
        let out = try #require(pipe.ingestBackdrop(solid(CGColor(red: 1, green: 0, blue: 0, alpha: 1), 20, 20)))
        let px = try #require(RGBAImage(bgra: out)).pixel(20, 20)
        #expect(px.r > 200 && px.g < 80)  // red now, black before
    }

    @Test func geometryAndPauseReportOnlyRealChanges() {
        let pipe = uniformPipe()
        let hole = [CGRect(x: 0, y: 0, width: 5, height: 5)]
        #expect(pipe.setGeometry(holes: hole, backdropCoverage: nil))
        #expect(!pipe.setGeometry(holes: hole, backdropCoverage: nil))
        #expect(pipe.setPaused(true))
        #expect(!pipe.setPaused(true))
        #expect(pipe.setPaused(false))
    }

    func textWindow(_ ink: NSColor, background: CGColor, _ w: Int = 480, _ h: Int = 120) -> CVPixelBuffer {
        captureBuffer(width: w, height: h) { ctx in
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let s = NSAttributedString(
                string: "GLASS CONTRAST", attributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: ink])
            ctx.textPosition = CGPoint(x: 20, y: 40)
            CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
    }

    @Test func analysisIdlesOnAStaticWindowAndWakesOnANewFrame() async throws {
        let p = GlassParameters(mode: .keyed(key: .white, tolerance: 0.05, softness: 0.05, contentAlpha: 1))
        let pipe = OverlayPipeline(options: .init(parameters: p), softwareRendering: true)
        pipe.ingestBackdrop(solid(CGColor(gray: 0.02, alpha: 1), 240, 60))
        pipe.ingestWindow(textWindow(.systemBlue, background: .white))
        var ticks = 0
        while await pipe.analyse(runOCR: false, dt: 0.1, scale: 0.5) {
            ticks += 1
            try #require(ticks < 200, "easing never settled")
        }
        _ = pipe.takeStats()
        for _ in 0..<20 { #expect(await !pipe.analyse(runOCR: true, dt: 0.1, scale: 0.5)) }
        let idle = pipe.takeStats()
        #expect(idle.analyses == 0 && idle.ocrRuns == 0)

        pipe.ingestWindow(textWindow(.systemBlue, background: .white))
        await pipe.analyse(runOCR: true, dt: 0.1, scale: 0.5)
        let woke = pipe.takeStats()
        #expect(woke.analyses == 1 && woke.ocrRuns == 1)
    }

    /// Dark mode, as on the owner's machine: dark window background, light text, bright backdrop.
    /// The background and a slightly lighter sidebar must turn to glass showing the backdrop's
    /// colour, and the light text must be recoloured dark to stay readable on the bright glass.
    @Test func darkModeWindowTurnsToGlassAndTextIsRecoloured() async throws {
        let pipe = OverlayPipeline(options: .init(transparency: .keyed), softwareRendering: true)
        let orange = CGColor(red: 0.95, green: 0.55, blue: 0.1, alpha: 1)
        pipe.ingestBackdrop(solid(orange, 240, 60))
        let window = captureBuffer(width: 480, height: 120) { ctx in
            ctx.setFillColor(CGColor(gray: 0.118, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 120))
            ctx.setFillColor(CGColor(gray: 0.17, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 120))
            let s = NSAttributedString(
                string: "GLASS CONTRAST",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor(white: 0.87, alpha: 1),
                ])
            ctx.textPosition = CGPoint(x: 30, y: 40)
            CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
        pipe.ingestWindow(window)
        var ticks = 0
        while await pipe.analyse(runOCR: ticks == 0, dt: 0.1, scale: 0.5), ticks < 100 { ticks += 1 }
        let style = try #require(pipe.currentStyles.first)
        #expect(style.color.oklab.L < 0.4)

        let out = try #require(pipe.composite())
        let img = try #require(RGBAImage(bgra: out))
        for (x, y) in [(470, 10), (8, 60)] {  // window background, sidebar
            let px = img.pixel(x, y)
            #expect(Int(px.r) - Int(px.b) > 60, "(\(x), \(y)) should show the orange backdrop, got \(px)")
        }
    }
}
