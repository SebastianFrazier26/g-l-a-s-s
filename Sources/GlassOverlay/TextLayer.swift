import CoreGraphics
import GlassContrast
import Vision

public enum TextRegionAnalysis {
    /// Caps per-region work; text regions are small, so a strided sample loses nothing visible.
    static let maxSamples = 2048

    static func pixels(in img: RGBAImage, rect: CGRect) -> [RGB] {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return [] }
        let count = Int(r.width * r.height)
        let step = max(1, Int((Double(count) / Double(maxSamples)).squareRoot().rounded(.up)))
        var out: [RGB] = []
        for y in stride(from: Int(r.minY), to: Int(r.maxY), by: step) {
            for x in stride(from: Int(r.minX), to: Int(r.maxX), by: step) { out.append(img.pixel(x, y).rgb) }
        }
        return out
    }

    static func bucket(_ c: RGB) -> Int {
        (Int(c.r * 15.999) << 8) | (Int(c.g * 15.999) << 4) | Int(c.b * 15.999)
    }

    /// The window's own background in a region: the most common colour (16 levels per channel).
    public static func dominantColor(in img: RGBAImage, rect: CGRect) -> RGB {
        let px = pixels(in: img, rect: rect)
        guard !px.isEmpty else { return .white }
        var groups: [Int: (n: Int, r: Double, g: Double, b: Double)] = [:]
        for c in px {
            let k = bucket(c)
            let e = groups[k] ?? (0, 0, 0, 0)
            groups[k] = (e.n + 1, e.r + c.r, e.g + c.g, e.b + c.b)
        }
        let m = groups.values.max { $0.n < $1.n }!
        return RGB(r: m.r / Double(m.n), g: m.g / Double(m.n), b: m.b / Double(m.n))
    }

    /// The ink colour: the pixels furthest from the background. Averaging all non-background pixels
    /// would pull the result toward the background through antialiased glyph edges.
    public static func textColor(in img: RGBAImage, rect: CGRect, background: RGB) -> RGB? {
        let px = pixels(in: img, rect: rect)
        let bg = background.oklab
        let ink = px.map { ($0, $0.oklab.distance(to: bg)) }.filter { $0.1 > 0.1 }
        guard !px.isEmpty, Double(ink.count) / Double(px.count) >= 0.02 else { return nil }
        let sorted = ink.sorted { $0.1 > $1.1 }
        let core = sorted.prefix(max(1, sorted.count * 3 / 10))
        let n = Double(core.count)
        return RGB(
            r: core.reduce(0) { $0 + $1.0.r } / n, g: core.reduce(0) { $0 + $1.0.g } / n,
            b: core.reduce(0) { $0 + $1.0.b } / n)
    }

    /// Text sits on a mostly uniform background in few colours; photos and video don't. Guards
    /// against recolouring pictures that OCR happened to box.
    public static func isLikelyText(in img: RGBAImage, rect: CGRect) -> Bool {
        let px = pixels(in: img, rect: rect)
        guard !px.isEmpty else { return false }
        let bg = bucket(dominantColor(in: img, rect: rect))
        var buckets = Set<Int>()
        var bgCount = 0
        for c in px {
            let k = bucket(c)
            if k == bg { bgCount += 1 } else { buckets.insert(k) }
        }
        return Double(bgCount) / Double(px.count) >= 0.4 && buckets.count <= 48
    }
}

public struct TrackedRegion: Equatable, Sendable {
    public let id: Int
    public var rect: CGRect

    public init(id: Int, rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

/// OCR boxes jitter between refreshes; matching by overlap keeps each line's colour state (and
/// so its easing) instead of restarting it from the original colour every refresh.
public enum RegionMatcher {
    public static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    public static func match(previous: [TrackedRegion], detected: [CGRect], nextID: inout Int) -> [TrackedRegion] {
        var used = Set<Int>()
        return detected.map { rect in
            let best = previous.filter { !used.contains($0.id) }.max { iou($0.rect, rect) < iou($1.rect, rect) }
            if let best, iou(best.rect, rect) >= 0.5 {
                used.insert(best.id)
                return TrackedRegion(id: best.id, rect: rect)
            }
            defer { nextID += 1 }
            return TrackedRegion(id: nextID, rect: rect)
        }
    }
}

/// Per text region: find the window's background and ink, estimate what will be behind the glyphs
/// once the glass is composited, and ease each region's colour with its own `AdaptiveTextColor`.
public struct TextLayerModel: Sendable {
    public var target: ContrastTarget
    public var parameters: GlassParameters
    public var urgentOmega: Double?
    public var hueShift: HueShiftPolicy
    public var allowScrim = true
    private var regions: [TrackedRegion] = []
    private var nextID = 0
    private var trackers: [Int: AdaptiveTextColor] = [:]

    public init(
        target: ContrastTarget, parameters: GlassParameters, urgentOmega: Double? = nil,
        hueShift: HueShiftPolicy = OwnerDefaults.hueShift
    ) {
        self.hueShift = hueShift
        self.target = target
        self.parameters = parameters
        self.urgentOmega = urgentOmega
    }

    /// `regions` are in the window capture's top-left pixel space; the backdrop may be lower
    /// resolution and is sampled proportionally.
    public mutating func update(regions rects: [CGRect], window: RGBAImage, backdrop: RGBAImage, dt: Double)
        -> [TextStyle]
    {
        regions = RegionMatcher.match(previous: regions, detected: rects, nextID: &nextID)
        let sx = Double(backdrop.width) / Double(max(window.width, 1))
        let sy = Double(backdrop.height) / Double(max(window.height, 1))
        var styles: [TextStyle] = []
        var alive = Set<Int>()

        for region in regions {
            guard TextRegionAnalysis.isLikelyText(in: window, rect: region.rect) else { continue }
            let bg = TextRegionAnalysis.dominantColor(in: window, rect: region.rect)
            guard let ink = TextRegionAnalysis.textColor(in: window, rect: region.rect, background: bg) else {
                continue
            }
            alive.insert(region.id)

            // Raw (unblurred) backdrop pixels: a conservative stand-in for the blurred glass, since
            // blur only narrows the range the text has to survive.
            let r = region.rect
            let raw = backdrop.sample(
                CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy))
            let behind = BackgroundSample(
                colors: raw.colors.map { parameters.effectiveBackground(backdrop: $0, windowBackground: bg) })

            var tracker =
                trackers[region.id].flatMap { $0.original.oklab.distance(to: ink.oklab) < 0.05 ? $0 : nil }
                ?? AdaptiveTextColor(
                    original: ink, solver: ContrastSolver(target: target, hueShift: hueShift), allowScrim: allowScrim,
                    urgentOmega: urgentOmega)
            _ = tracker.update(background: behind, dt: dt)
            trackers[region.id] = tracker
            styles.append(
                TextStyle(
                    rect: region.rect, regionBackground: bg, color: tracker.current, scrim: tracker.scrim,
                    scrimOpacity: tracker.scrimOpacity))
        }
        trackers = trackers.filter { alive.contains($0.key) }
        return styles
    }
}

/// Finds text lines with Vision. `.fast` because boxes, not words, are what the overlay needs.
public struct VisionTextDetector: Sendable {
    public init() {}

    /// Returns line boxes in top-left pixel coordinates of `image`.
    public func detect(in image: CGImage) async throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let w = Double(image.width), h = Double(image.height)
        return (request.results ?? []).map { obs in
            let b = obs.boundingBox  // normalised, bottom-left origin
            return CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        }
    }
}
