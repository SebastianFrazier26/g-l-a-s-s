import CoreImage
import CoreVideo
import Foundation
import GlassContrast

/// Glue between capture callbacks (any thread), the slower text analysis loop, and the compositor.
/// State is behind one lock; nothing here blocks on the main thread.
public final class OverlayPipeline: @unchecked Sendable {
    public struct Options: Sendable {
        public var parameters: GlassParameters
        public var target: ContrastTarget = OwnerDefaults.contrastTarget
        public var urgentOmega: Double? = OwnerDefaults.urgentOmega
        public var textEnabled = true
        /// Key colour comes from the window itself when nil (its dominant colour).
        public var fixedKey: RGB?

        public init(parameters: GlassParameters) { self.parameters = parameters }
    }

    private let lock = NSLock()
    private let compositor: GlassCompositor
    private let detector = VisionTextDetector()
    private var options: Options
    private var textModel: TextLayerModel
    private var backdrop: CIImage?
    private var windowFrame: CIImage?
    private var styles: [TextStyle] = []
    private var regions: [CGRect] = []
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var analysisTask: Task<Void, Never>?
    private var holes: [CGRect] = []
    private var backdropCoverage: CGRect?
    private var paused = false

    public init(options: Options, softwareRendering: Bool = false) {
        self.options = options
        compositor = GlassCompositor(softwareRendering: softwareRendering)
        textModel = TextLayerModel(
            target: options.target, parameters: options.parameters, urgentOmega: options.urgentOmega)
    }

    public func ingestBackdrop(_ buffer: CVPixelBuffer) {
        let img = CIImage(cvPixelBuffer: buffer)
        lock.withLock { backdrop = img }
    }

    /// Composites against the latest backdrop and returns a buffer ready for `CALayer.contents`.
    public func ingestWindow(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let window = CIImage(cvPixelBuffer: buffer)
        let (bd, params, text, holes, coverage, paused) = lock.withLock {
            windowFrame = window
            return (
                backdrop, options.parameters, options.textEnabled ? styles : [], self.holes, backdropCoverage,
                self.paused
            )
        }
        guard !paused, let bd, let out = outputBuffer(for: window.extent.size) else { return nil }
        let image = compositor.compose(
            backdrop: bd, window: window, parameters: params, text: text, holes: holes, backdropCoverage: coverage)
        compositor.render(image, into: out)
        return out
    }

    /// Text analysis at `hz`, OCR every `ocrEvery` ticks. Kept off the capture path: OCR takes
    /// tens of milliseconds and the colour model only needs a few updates per second.
    public func startAnalysis(hz: Double = 10, ocrEvery: Int = 5, analysisScale: Double = 0.5) {
        analysisTask?.cancel()
        analysisTask = Task.detached(priority: .utility) { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.analyse(runOCR: tick % ocrEvery == 0, dt: 1 / hz, scale: analysisScale)
                tick += 1
                try? await Task.sleep(for: .milliseconds(Int(1000 / hz)))
            }
        }
    }

    public func stop() { analysisTask?.cancel() }

    /// Geometry in window-capture pixels (top-left): see `GlassCompositor.compose`.
    public func setGeometry(holes: [CGRect], backdropCoverage: CGRect?) {
        lock.withLock {
            self.holes = holes
            self.backdropCoverage = backdropCoverage
        }
    }

    /// Skips compositing (and the GPU work) while the target is hidden or fully covered.
    public func setPaused(_ value: Bool) { lock.withLock { paused = value } }

    var currentStyles: [TextStyle] { lock.withLock { styles } }

    func analyse(runOCR: Bool, dt: Double, scale: Double) async {
        let (win, bd, opts) = lock.withLock { (windowFrame, backdrop, options) }
        guard opts.textEnabled, let win, let bd else { return }
        let full = win.extent
        if runOCR, let cg = compositor.renderCGImage(win) {
            let found = (try? await detector.detect(in: cg)) ?? []
            lock.withLock { regions = found }
        }
        let small = win.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(full.width * scale), h = Int(full.height * scale)
        let bdScale = CGAffineTransform(scaleX: Double(w) / bd.extent.width, y: Double(h) / bd.extent.height)
        guard w > 0, h > 0,
            let winPx = compositor.renderRGBA(small, width: w, height: h),
            let bdPx = compositor.renderRGBA(bd.transformed(by: bdScale), width: w, height: h)
        else { return }

        var params = opts.parameters
        if case .keyed(_, let t, let s, let a) = params.mode {
            let key =
                opts.fixedKey
                ?? TextRegionAnalysis.dominantColor(in: winPx, rect: CGRect(x: 0, y: 0, width: w, height: h))
            params.mode = .keyed(key: key, tolerance: t, softness: s, contentAlpha: a)
        }
        let rects = lock.withLock { regions }.map {
            CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale)
        }
        let newStyles: [TextStyle] = lock.withLock {
            textModel.parameters = params
            options.parameters = params
            return textModel.update(regions: rects, window: winPx, backdrop: bdPx, dt: dt)
        }.map { s in
            var full = s
            full.rect = CGRect(
                x: s.rect.minX / scale, y: s.rect.minY / scale, width: s.rect.width / scale,
                height: s.rect.height / scale)
            return full
        }
        lock.withLock { styles = newStyles }
    }

    private func outputBuffer(for size: CGSize) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if pool == nil || size != poolSize {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }
}
