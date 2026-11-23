public enum Gamut {
    /// Largest in-sRGB-gamut chroma for a given OKLCH lightness and hue, by bisection.
    /// Along a fixed-L, fixed-h chroma ray the in-gamut set is in practice a single interval from C = 0
    /// (CSS Color 4's gamut-mapping search relies on the same property), so bisection finds its edge.
    public static func maxChroma(lightness L: Double, hue h: Double) -> Double {
        if L <= 0 || L >= 1 { return 0 }
        var lo = 0.0, hi = 0.5
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            if OKLCH(L: L, C: mid, h: h).isInGamut { lo = mid } else { hi = mid }
        }
        return lo
    }
}
