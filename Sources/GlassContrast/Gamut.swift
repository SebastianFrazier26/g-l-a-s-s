/// The colours the target display can show. `RGB` stays gamma-encoded sRGB throughout; a Display P3
/// colour outside sRGB is carried as *extended* sRGB (channels below 0 or above 1), the same
/// convention as `CGColorSpace.extendedSRGB`. That keeps every metric and conversion unchanged for
/// in-sRGB colours, rather than threading a second encoding through the engine.
public enum ColorGamut: String, Sendable, Hashable, CaseIterable {
    case sRGB
    case displayP3

    /// Linear sRGB → linear Display P3 (both D65), derived from the two sets of primaries.
    static func toP3(_ c: LinearRGB) -> LinearRGB {
        LinearRGB(
            r: 0.8224619687 * c.r + 0.1775380313 * c.g,
            g: 0.0331941989 * c.r + 0.9668058011 * c.g,
            b: 0.0170826307 * c.r + 0.0723974407 * c.g + 0.9105199286 * c.b)
    }

    static func fromP3(_ c: LinearRGB) -> LinearRGB {
        LinearRGB(
            r: 1.2249401763 * c.r - 0.2249401763 * c.g,
            g: -0.0420569547 * c.r + 1.0420569547 * c.g,
            b: -0.0196375546 * c.r - 0.0786360456 * c.g + 1.0982736001 * c.b)
    }

    public func contains(_ c: RGB) -> Bool {
        switch self {
        case .sRGB: return c.isInGamut
        case .displayP3:
            let e = 1e-9
            let p = Self.toP3(c.linear)
            return (-e...(1 + e)).contains(p.r) && (-e...(1 + e)).contains(p.g) && (-e...(1 + e)).contains(p.b)
        }
    }

    /// Per-channel clip in this gamut's own channels. Only a safety net for float noise and junk
    /// input: the solver reaches the gamut by reducing chroma, which keeps hue.
    public func clamp(_ c: RGB) -> RGB {
        switch self {
        case .sRGB: return c.clamped()
        case .displayP3:
            if contains(c) { return c }
            let p = Self.toP3(c.linear)
            func k(_ x: Double) -> Double { min(max(x, 0), 1) }
            return Self.fromP3(LinearRGB(r: k(p.r), g: k(p.g), b: k(p.b))).encoded
        }
    }

    public func contains(_ c: OKLCH) -> Bool { contains(c.rgb) }
}

public enum Gamut {
    /// Largest in-gamut chroma for a given OKLCH lightness and hue, by bisection.
    /// Along a fixed-L, fixed-h chroma ray the in-gamut set is in practice a single interval from C = 0
    /// (CSS Color 4's gamut-mapping search relies on the same property), so bisection finds its edge.
    public static func maxChroma(lightness L: Double, hue h: Double, in gamut: ColorGamut = .sRGB) -> Double {
        if L <= 0 || L >= 1 { return 0 }
        var lo = 0.0, hi = 0.5
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            if gamut.contains(OKLCH(L: L, C: mid, h: h)) { lo = mid } else { hi = mid }
        }
        return lo
    }
}
