import Foundation

/// Gamma-encoded sRGB, channels nominally in 0...1.
public struct RGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255)
    }

    public var linear: LinearRGB { LinearRGB(r: srgbToLinear(r), g: srgbToLinear(g), b: srgbToLinear(b)) }
    public var oklab: OKLab { linear.oklab }
    public var oklch: OKLCH { oklab.lch }

    /// Tolerance absorbs float noise from OKLab round trips at the gamut boundary.
    public var isInGamut: Bool {
        let e = 1e-9
        return (-e...(1 + e)).contains(r) && (-e...(1 + e)).contains(g) && (-e...(1 + e)).contains(b)
    }

    public func clamped() -> RGB {
        RGB(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1))
    }
}

public struct LinearRGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var encoded: RGB { RGB(r: linearToSRGB(r), g: linearToSRGB(g), b: linearToSRGB(b)) }

    // Matrices from Björn Ottosson, "A perceptual color space for image processing" (2020),
    // https://bottosson.github.io/posts/oklab/ — the same values CSS Color 4 specifies.
    public var oklab: OKLab {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return OKLab(
            L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }
}

public struct OKLab: Hashable, Sendable {
    public var L: Double
    public var a: Double
    public var b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }

    public var linear: LinearRGB {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return LinearRGB(
            r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    public var rgb: RGB { linear.encoded }

    public var lch: OKLCH {
        let c = (a * a + b * b).squareRoot()
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return OKLCH(L: L, C: c, h: h)
    }

    /// Euclidean distance in OKLab (ΔE_OK). CSS Color 4 treats 0.02 as one just-noticeable difference.
    public func distance(to o: OKLab) -> Double {
        let dL = L - o.L, da = a - o.a, db = b - o.b
        return (dL * dL + da * da + db * db).squareRoot()
    }
}

/// Polar OKLab. Hue in degrees, 0..<360.
public struct OKLCH: Hashable, Sendable {
    public var L: Double
    public var C: Double
    public var h: Double

    public init(L: Double, C: Double, h: Double) {
        self.L = L
        self.C = C
        self.h = h
    }

    public var lab: OKLab {
        let rad = h * .pi / 180
        return OKLab(L: L, a: C * cos(rad), b: C * sin(rad))
    }

    public var rgb: RGB { lab.rgb }
    public var isInGamut: Bool { lab.linear.encoded.isInGamut }

    /// Chroma reduction at fixed L and h (the CSS Color 4 strategy, minus its clipping shortcut).
    public func gamutMapped() -> OKLCH {
        if isInGamut { return self }
        return OKLCH(L: L, C: min(C, Gamut.maxChroma(lightness: L, hue: h)), h: h)
    }
}

/// IEC 61966-2-1 sRGB decoding.
@inlinable public func srgbToLinear(_ c: Double) -> Double {
    let a = abs(c)
    let v = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
    return c < 0 ? -v : v
}

@inlinable public func linearToSRGB(_ c: Double) -> Double {
    let a = abs(c)
    let v = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
    return c < 0 ? -v : v
}
