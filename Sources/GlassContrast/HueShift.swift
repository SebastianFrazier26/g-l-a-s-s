import Foundation

/// When and how far the solver may move a text colour's hue and chroma, not just its lightness.
///
/// Owner decision 2026-11-23 (DESIGN §6 item 2): hue and chroma may move when that reaches the
/// target with a clearly smaller perceptual change than lightness alone.
///
/// APCA and WCAG score luminance only, so hue never makes an impossible background possible: if
/// white or black can't reach the target, nothing can. What a hue move buys is a *smaller* change.
/// At equal OKLab L, yellows and greens carry far more luminance than blues and purples. So a
/// yellow that must darken reaches the target sooner by leaning toward orange than by sinking to
/// olive, and a blue that must lighten gets there sooner by leaning toward azure.
public struct HueShiftPolicy: Sendable, Hashable {
    public enum Strategy: Sendable, Hashable {
        /// The pre-2026-11-23 behaviour: hue fixed, chroma only reduced where the gamut forces it.
        case lightnessOnly
        /// Search all allowed hues and chromas for the passing colour with the smallest ΔE_OK.
        case nearest
        /// As `nearest`, but hue may only rotate from the original toward the complement of the
        /// background's hue, never toward the background's own hue. This is an option, not the
        /// default: the metric is luminance-only, so the restriction buys no measured contrast and
        /// usually costs a larger change. Over an achromatic background it behaves as `nearest`.
        case complementary
    }

    public var strategy: Strategy
    /// How far chroma may rise above the original, in OKLCH C. With 0, the text never becomes more
    /// saturated than it started, and grey text stays grey.
    public var maxChromaGain: Double
    /// Largest hue rotation in degrees, so a red error can't drift into a cyan.
    public var maxHueShift: Double
    /// ΔE_OK a hue/chroma move must save over lightness-only before it is used. This is how
    /// "prefer lightness-only" is applied, and it doubles as the hysteresis band between the two modes.
    public var advantage: Double
    /// Extra weight on losing chroma, in the cost both modes are compared by. With 1 that cost is
    /// exactly ΔE_OK. But plain ΔE barely rewards a hue move: the luminance the target needs pins
    /// OKLab L, and turning hue changes luminance at fixed L only slightly. What lightness-only
    /// really loses is colourfulness, near L = 0 or 1 where the gamut forces chroma toward grey.
    /// Weighting that loss is what lets a hue with more gamut room at the new lightness win.
    public var chromaLossWeight: Double
    /// Weight on closeness to the previous target when choosing among hue/chroma candidates. It
    /// stops two near-equal hue branches (leaning one way or the other) from alternating frame to frame.
    public var continuity: Double

    public init(
        strategy: Strategy, maxChromaGain: Double = 0, maxHueShift: Double = 60, advantage: Double = 0.03,
        chromaLossWeight: Double = 2, continuity: Double = 0.15
    ) {
        self.chromaLossWeight = chromaLossWeight
        self.strategy = strategy
        self.maxChromaGain = maxChromaGain
        self.maxHueShift = maxHueShift
        self.advantage = advantage
        self.continuity = continuity
    }

    public static let lightnessOnly = HueShiftPolicy(strategy: .lightnessOnly)
    public static let `default` = HueShiftPolicy(strategy: .nearest)

    /// ΔE_OK split into lightness, chroma and hue parts, with chroma loss scaled by `chromaLossWeight`.
    public func cost(from original: OKLCH, to candidate: OKLCH) -> Double {
        let dL = candidate.L - original.L
        let loss = max(original.C - candidate.C, 0) * chromaLossWeight
        let gain = max(candidate.C - original.C, 0)
        let dH =
            2 * (original.C * candidate.C).squareRoot()
            * sin(abs(signedHueDelta(from: original.h, to: candidate.h)) * .pi / 360)
        return (dL * dL + loss * loss + gain * gain + dH * dH).squareRoot()
    }
}

extension ContrastSolver {
    /// Passing colour on `side` closest to `original`, allowing hue and chroma to move under `hueShift`.
    /// Returns nil when no in-gamut candidate verifies.
    func shiftSearch(
        from original: OKLCH, toward side: Polarity, _ bg: BackgroundSample.Summary, background: BackgroundSample,
        previous: OKLab?
    ) -> Candidate? {
        let policy = hueShift
        let cMax = original.C + max(policy.maxChromaGain, 0)
        // With no chroma to spend there is no hue to move, so the lightness-only result is optimal.
        guard cMax > 0.01, let yStar = boundaryLuminance(side, bg) else { return nil }

        let span = min(max(policy.maxHueShift, 0), 180)
        let range: ClosedRange<Double>
        switch policy.strategy {
        case .lightnessOnly: return nil
        case .nearest: range = -span...span
        case .complementary:
            if let bgHue = Self.dominantHue(background) {
                let away = signedHueDelta(from: bgHue, to: original.h)
                let toComplement = min(180 - abs(away), span)
                range = away >= 0 ? 0...toComplement : -toComplement...0
            } else {
                range = -span...span
            }
        }

        func evaluate(_ dh: Double, _ c: Double) -> (Candidate, Double)? {
            let h = (original.h + dh).truncatingRemainder(dividingBy: 360)
            guard let cand = point(hue: h < 0 ? h + 360 : h, chroma: c, yStar: yStar, side: side, bg) else {
                return nil
            }
            var cost = policy.cost(from: original, to: cand.color.oklch)
            if let previous { cost += policy.continuity * cand.color.oklab.distance(to: previous) }
            return (cand, cost)
        }

        var best: (dh: Double, c: Double, cand: Candidate, cost: Double)?
        let hueStep = 15.0
        let hueCount = max(Int((range.upperBound - range.lowerBound) / hueStep), 1)
        let chromaLevels = 4
        for i in 0...hueCount {
            let dh = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(hueCount)
            for k in 0...chromaLevels {
                let c = cMax * Double(k) / Double(chromaLevels)
                if k == 0 && i > 0 { continue }  // C = 0 is the same grey at every hue
                if let (cand, cost) = evaluate(dh, c), cost < (best?.cost ?? .infinity) {
                    best = (dh, c, cand, cost)
                }
            }
        }
        guard var b = best else { return nil }

        // Pattern search from the best grid point: the grid only has to land in the right basin.
        var dhStep = hueStep / 2, cStep = cMax / Double(chromaLevels) / 2
        while dhStep > 0.25 || cStep > 0.001 {
            var improved = false
            for (ddh, dc) in [(dhStep, 0.0), (-dhStep, 0.0), (0.0, cStep), (0.0, -cStep)] {
                let dh = min(max(b.dh + ddh, range.lowerBound), range.upperBound)
                let c = min(max(b.c + dc, 0), cMax)
                if let (cand, cost) = evaluate(dh, c), cost < b.cost - 1e-9 {
                    b = (dh, c, cand, cost)
                    improved = true
                }
            }
            if !improved {
                dhStep /= 2
                cStep /= 2
            }
        }
        return b.cand
    }

    /// The text luminance (on the target's own luminance scale) at which `side` just passes.
    /// The score depends on text luminance alone, so a grey probe finds it once for every hue.
    private func boundaryLuminance(_ side: Polarity, _ bg: BackgroundSample.Summary) -> Double? {
        func passes(_ g: Double) -> Bool {
            let (s, p) = worstCase(RGB(r: g, g: g, b: g), bg)
            return p == side && s >= target.threshold
        }
        var fail = side == .lighter ? 0.0 : 1.0
        var pass = side == .lighter ? 1.0 : 0.0
        guard passes(pass) else { return nil }
        for _ in 0..<40 {
            let mid = (fail + pass) / 2
            if passes(mid) { pass = mid } else { fail = mid }
        }
        return target.luminance(RGB(r: pass, g: pass, b: pass))
    }

    /// The in-gamut colour at this hue and chroma whose luminance sits on the passing side of `yStar`,
    /// as close to it as bisection allows. Every result is re-scored, so a claim of success is verified.
    private func point(hue: Double, chroma: Double, yStar: Double, side: Polarity, _ bg: BackgroundSample.Summary)
        -> Candidate?
    {
        func lum(_ L: Double) -> Double { target.luminance(OKLCH(L: L, C: chroma, h: hue).rgb.clamped()) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<26 {
            let mid = (lo + hi) / 2
            if lum(mid) >= yStar { hi = mid } else { lo = mid }
        }
        let L = side == .lighter ? hi : lo
        let lch = OKLCH(L: L, C: chroma, h: hue)
        guard lch.isInGamut else { return nil }
        let color = lch.rgb.clamped()
        let (s, p) = worstCase(color, bg)
        guard p == side, s >= target.threshold else { return nil }
        return Candidate(color: color, polarity: side, score: s, feasible: true, hueShifted: true)
    }

    /// Weighted mean hue of the background in OKLab, or nil when it is too close to grey to have one.
    static func dominantHue(_ bg: BackgroundSample) -> Double? {
        var a = 0.0, b = 0.0, w = 0.0
        for (c, wt) in zip(bg.colors, bg.weights) {
            let lab = c.clamped().oklab
            a += lab.a * wt
            b += lab.b * wt
            w += wt
        }
        guard w > 0 else { return nil }
        let mean = OKLab(L: 0, a: a / w, b: b / w).lch
        return mean.C < 0.02 ? nil : mean.h
    }
}

/// Signed shortest rotation in degrees from `a` to `b`, in -180...180.
func signedHueDelta(from a: Double, to b: Double) -> Double {
    var d = (b - a).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
