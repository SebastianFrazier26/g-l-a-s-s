import CoreGraphics
import CoreImage
import GlassContrast

public enum WindowMode: Sendable, Equatable {
    /// The whole window copy at one opacity. Simple, but its text fades along with everything else.
    case uniform(alpha: Double)
    /// Pixels close to `key` (the window's own background colour) become transparent and the
    /// content stays at `contentAlpha`. Distance is the sum of per-channel differences in linear
    /// light (0...3); `tolerance` is fully keyed, and the ramp to opaque is `softness` wide.
    case keyed(key: RGB, tolerance: Double, softness: Double, contentAlpha: Double)
}

public struct GlassParameters: Sendable, Equatable {
    public var mode: WindowMode
    public var blurRadius: Double = GlassLook.default.blurRadius
    public var tint: RGB = .white
    public var tintOpacity: Double = GlassLook.default.tintOpacity

    public init(mode: WindowMode) { self.mode = mode }

    /// What the eye sees behind a glyph once the window's text is replaced: the solver's input.
    public func effectiveBackground(backdrop: RGB, windowBackground: RGB) -> RGB {
        let glass = ScrimResult.blend(backdrop, over: tint, opacity: tintOpacity)
        switch mode {
        case .uniform(let alpha): return ScrimResult.blend(glass, over: windowBackground, opacity: alpha)
        case .keyed: return glass
        }
    }
}

/// One text region to restyle, in top-left pixel coordinates of the window capture.
public struct TextStyle: Sendable, Equatable {
    public var rect: CGRect
    /// The window's own background inside this region; glyph pixels are those that differ from it.
    public var regionBackground: RGB
    public var color: RGB
    public var scrim: RGB
    public var scrimOpacity: Double
    public var glyphTolerance: Double = 0.15
    public var glyphSoftness: Double = 0.3

    public init(rect: CGRect, regionBackground: RGB, color: RGB, scrim: RGB, scrimOpacity: Double) {
        self.rect = rect
        self.regionBackground = regionBackground
        self.color = color
        self.scrim = scrim
        self.scrimOpacity = scrimOpacity
    }
}

/// Blurred, tinted backdrop + translucent window copy + restyled text, all as Core Image graphs.
///
/// Core Image rather than hand-written Metal for the spike: every stage is a stock filter that runs
/// on the GPU in the app and on the CPU (`softwareRendering`) in tests, so the pipeline is verified
/// against synthetic frames without Screen Recording. Blending happens in linear light (the working
/// space), matching how the solver models the glass.
public final class GlassCompositor: @unchecked Sendable {
    let context: CIContext
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Text colours arrive as extended sRGB (Display P3 colours fall outside 0...1), so constants
    /// are built in this space rather than sRGB, which would clip them.
    static let extendedSRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    public init(softwareRendering: Bool = false) {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .outputColorSpace: Self.sRGB,
            .useSoftwareRenderer: softwareRendering,
            .cacheIntermediates: false,
        ])
    }

    /// - Parameters:
    ///   - holes: top-left pixel rects left fully transparent, so windows in front of the target
    ///     (menus, popovers, other apps) show through untouched.
    ///   - backdropCoverage: top-left pixel rect of the window the backdrop was captured for, when
    ///     the window straddles displays; nil means the backdrop covers the whole window.
    public func compose(
        backdrop: CIImage, window: CIImage, parameters p: GlassParameters, text: [TextStyle] = [],
        holes: [CGRect] = [], backdropCoverage: CGRect? = nil
    ) -> CIImage {
        let extent = window.extent
        var glass = fitted(backdrop, to: backdropCoverage.map { ciRect($0, in: extent) } ?? extent)
        if p.blurRadius > 0 {
            glass = glass.clampedToExtent().applyingGaussianBlur(sigma: p.blurRadius).cropped(to: extent)
        } else {
            glass = glass.clampedToExtent().cropped(to: extent)
        }
        if p.tintOpacity > 0 {
            glass = constant(p.tint, alpha: p.tintOpacity, extent).composited(over: glass)
        }

        var out: CIImage
        switch p.mode {
        case .uniform(let alpha):
            out = window.applyingFilter(
                "CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)]
            ).composited(over: glass)
        case .keyed(let key, let tolerance, let softness, let contentAlpha):
            // Transparent capture pixels (window shadow, rounded corners) become key colour, so they
            // are keyed out rather than darkening the glass.
            let opaque = window.composited(over: constant(key, alpha: 1, extent))
            let mask = differenceMask(opaque, from: key, tolerance: tolerance, softness: softness, scale: contentAlpha)
            out = opaque.applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [kCIInputBackgroundImageKey: glass, kCIInputMaskImageKey: mask])
        }

        for style in text {
            let r = ciRect(style.rect, in: extent)
            if style.scrimOpacity > 0 {
                out = constant(style.scrim, alpha: style.scrimOpacity, r).composited(over: out)
            }
            let glyphs = differenceMask(
                window.composited(over: constant(style.regionBackground, alpha: 1, extent)),
                from: style.regionBackground, tolerance: style.glyphTolerance, softness: style.glyphSoftness,
                scale: 1
            ).cropped(to: r)
            out = constant(style.color, alpha: 1, r).applyingFilter(
                "CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: glyphs])
        }
        if !holes.isEmpty {
            let cut = holes.reduce(CIImage.empty()) {
                constant(.black, alpha: 1, ciRect($1, in: extent)).composited(over: $0)
            }
            out = out.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: cut])
        }
        return out.cropped(to: extent)
    }

    public func renderRGBA(_ image: CIImage, width: Int, height: Int) -> RGBAImage? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &data, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: Self.sRGB)
        return RGBAImage(width: width, height: height, data: data)
    }

    /// GPU path for the live overlay: render into an IOSurface-backed buffer that a CALayer can
    /// display directly, avoiding a CGImage readback per frame.
    /// `gamut` is the display's: P3 on P3 displays so wide-gamut text survives. Analysis readbacks
    /// (`renderRGBA`, `renderCGImage`) stay sRGB, matching the captures.
    public func render(_ image: CIImage, into buffer: CVPixelBuffer, gamut: ColorGamut = .sRGB) {
        let space = gamut.cgColorSpace
        // Tag the buffer, otherwise the layer assumes sRGB and P3 values would be reinterpreted.
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        context.render(image, to: buffer, bounds: image.extent, colorSpace: space)
    }

    public func renderCGImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Self.sRGB)
    }

    /// Captures are top-left; Core Image is bottom-left.
    func ciRect(_ r: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + r.minX, y: extent.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The backdrop stream runs at half resolution (it gets blurred anyway), so scale it up.
    func fitted(_ img: CIImage, to extent: CGRect) -> CIImage {
        guard img.extent != extent, img.extent.width > 0, img.extent.height > 0 else { return img }
        let sx = extent.width / img.extent.width, sy = extent.height / img.extent.height
        return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    func constant(_ c: RGB, alpha: Double, _ extent: CGRect) -> CIImage {
        let color =
            CIColor(red: c.r, green: c.g, blue: c.b, alpha: alpha, colorSpace: Self.extendedSRGB)
            ?? CIColor(red: c.r, green: c.g, blue: c.b, alpha: alpha)
        return CIImage(color: color).cropped(to: extent)
    }

    /// Alpha = clamp((Σ|pixel − key| − tolerance) / softness) × scale, in linear light.
    func differenceMask(_ image: CIImage, from key: RGB, tolerance: Double, softness: Double, scale: Double)
        -> CIImage
    {
        let diff = image.applyingFilter(
            "CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: constant(key, alpha: 1, image.extent)])
        let g = 1 / max(softness, 1e-6), b = -tolerance * g
        let sum = CIVector(x: g, y: g, z: g, w: 0)
        return diff.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": sum, "inputGVector": sum, "inputBVector": sum, "inputAVector": sum,
                "inputBiasVector": CIVector(x: b, y: b, z: b, w: b),
            ]
        )
        .applyingFilter("CIColorClamp")
        .applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: scale),
            ])
    }
}
