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
        public var hueShift: HueShiftPolicy = OwnerDefaults.hueShift
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
    /// Bumped on every captured frame; analysis skips ticks where nothing new arrived and the
    /// easing has settled, instead of re-running OCR and colour analysis on a static window.
    private var inputGeneration = 0
    private var windowGeneration = 0
    private var analysedGeneration = -1
    private var ocrGeneration = -1
    private var settled = false
    private let renderLock = NSLock()
    private var counters = Stats()

    /// Event counts since the last `takeStats()`, for the spike's periodic log line.
    public struct Stats: Sendable, Equatable {
        public var windowFrames = 0
        public var backdropFrames = 0
        public var composites = 0
        public var analyses = 0
        public var ocrRuns = 0
    }
    private var displayGamut = ColorGamut.sRGB

    public init(options: Options, softwareRendering: Bool = false) {
        self.options = options
        compositor = GlassCompositor(softwareRendering: softwareRendering)
        textModel = TextLayerModel(
            target: options.target, parameters: options.parameters, urgentOmega: options.urgentOmega,
            hueShift: options.hueShift)
    }

    /// Call when the window lands on a display (at start and whenever it moves to another one).
    public func setDisplayGamut(_ gamut: ColorGamut) {
        lock.withLock {
            textModel.gamut = gamut
            displayGamut = gamut
            settled = false  // the solver's gamut changed, so idle analysis must re-solve
        }
    }

    /// Every input re-composites, not only window frames: ScreenCaptureKit delivers a frame only
    /// when pixels change, so a static window would otherwise never be drawn once its first frame
    /// arrived before the first backdrop frame, and backdrop motion would never reach the glass.
    @discardableResult
    public func ingestBackdrop(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let img = CIImage(cvPixelBuffer: buffer)
        lock.withLock {
            backdrop = img
            inputGeneration += 1
            counters.backdropFrames += 1
        }
        return composite()
    }

    /// Composites against the latest backdrop and returns a buffer ready for `CALayer.contents`.
    @discardableResult
    public func ingestWindow(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let window = CIImage(cvPixelBuffer: buffer)
        lock.withLock {
            windowFrame = window
            inputGeneration += 1
            windowGeneration += 1
            counters.windowFrames += 1
        }
        return composite()
    }

    /// Composites the latest window and backdrop frames with the current styles and geometry; nil
    /// until both streams have delivered, or while paused.
    public func composite() -> CVPixelBuffer? {
        // Serialised: callers are two capture queues and the analysis task, and presenting two
        // renders out of order would flash a stale frame.
        renderLock.lock()
        defer { renderLock.unlock() }
        let (win, bd, params, text, holes, coverage, paused, gamut) = lock.withLock {
            (
                windowFrame, backdrop, options.parameters, options.textEnabled ? styles : [], self.holes,
                backdropCoverage, self.paused, displayGamut
            )
        }
        guard !paused, let win, let bd, let out = outputBuffer(for: win.extent.size) else { return nil }
        let image = compositor.compose(
            backdrop: bd, window: win, parameters: params, text: text, holes: holes, backdropCoverage: coverage)
        compositor.render(image, into: out, gamut: gamut)
        lock.withLock { counters.composites += 1 }
        return out
    }

    public func takeStats() -> Stats {
        lock.withLock {
            defer { counters = Stats() }
            return counters
        }
    }

    /// Text analysis at `hz`, OCR every `ocrEvery` ticks. Kept off the capture path: OCR takes
    /// tens of milliseconds and the colour model only needs a few updates per second.
    /// `onChange` runs (off the main thread) when the text styles moved, so the caller can
    /// re-composite and present.
    public func startAnalysis(
        hz: Double = 10, ocrEvery: Int = 5, analysisScale: Double = 0.5, onChange: @escaping @Sendable () -> Void = {}
    ) {
        analysisTask?.cancel()
        analysisTask = Task.detached(priority: .utility) { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if await self?.analyse(runOCR: tick % ocrEvery == 0, dt: 1 / hz, scale: analysisScale) == true {
                    onChange()
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(Int(1000 / hz)))
            }
        }
    }

    public func stop() { analysisTask?.cancel() }

    /// Geometry in window-capture pixels (top-left): see `GlassCompositor.compose`. Returns whether
    /// anything changed, i.e. whether the caller should re-composite.
    @discardableResult
    public func setGeometry(holes: [CGRect], backdropCoverage: CGRect?) -> Bool {
        lock.withLock {
            guard holes != self.holes || backdropCoverage != self.backdropCoverage else { return false }
            self.holes = holes
            self.backdropCoverage = backdropCoverage
            return true
        }
    }

    /// Skips compositing (and the GPU work) while the target is hidden or fully covered. Returns
    /// whether the state changed.
    @discardableResult
    public func setPaused(_ value: Bool) -> Bool {
        lock.withLock {
            defer { paused = value }
            return paused != value
        }
    }

    var currentStyles: [TextStyle] { lock.withLock { styles } }

    /// Returns whether the styles visibly changed. Skips all work when no frame arrived since the
    /// last run and the easing has settled.
    @discardableResult
    func analyse(runOCR: Bool, dt: Double, scale: Double) async -> Bool {
        let (win, bd, opts, gen, winGen, ocrDone, firstRun, idle) = lock.withLock {
            let ocrDone = ocrGeneration == windowGeneration
            return (
                windowFrame, backdrop, options, inputGeneration, windowGeneration, ocrDone, analysedGeneration < 0,
                settled && ocrDone && inputGeneration == analysedGeneration
            )
        }
        guard opts.textEnabled, let win, let bd, !idle else { return false }
        lock.withLock { counters.analyses += 1 }
        let full = win.extent
        if runOCR || firstRun, !ocrDone, let cg = compositor.renderCGImage(win) {
            let found = (try? await detector.detect(in: cg)) ?? []
            lock.withLock {
                regions = found
                ocrGeneration = winGen
                counters.ocrRuns += 1
            }
        }
        let small = win.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(full.width * scale), h = Int(full.height * scale)
        let bdScale = CGAffineTransform(scaleX: Double(w) / bd.extent.width, y: Double(h) / bd.extent.height)
        guard w > 0, h > 0,
            let winPx = compositor.renderRGBA(small, width: w, height: h),
            let bdPx = compositor.renderRGBA(bd.transformed(by: bdScale), width: w, height: h)
        else { return false }

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
        return lock.withLock {
            let changed = !Self.visiblySame(styles, newStyles) || params != opts.parameters
            styles = newStyles
            analysedGeneration = gen
            settled = !changed
            return changed
        }
    }

    /// Half an 8-bit step: below that a re-composite draws identical pixels.
    static func visiblySame(_ a: [TextStyle], _ b: [TextStyle]) -> Bool {
        let eps = 0.5 / 255
        func near(_ x: RGB, _ y: RGB) -> Bool { abs(x.r - y.r) < eps && abs(x.g - y.g) < eps && abs(x.b - y.b) < eps }
        return a.count == b.count
            && zip(a, b).allSatisfy { s, t in
                s.rect == t.rect && s.regionBackground == t.regionBackground && near(s.color, t.color)
                    && near(s.scrim, t.scrim) && abs(s.scrimOpacity - t.scrimOpacity) < eps
            }
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
