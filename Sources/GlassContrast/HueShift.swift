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
        /// Owner's default (2026-11-23). Hue may only rotate from the original toward the complement of
        /// the backdrop's mean hue, never toward the backdrop's own hue, and within that arc the
        /// smallest change wins. Hue contrast against the backdrop then adds to the luminance contrast
        /// the metric measures. Over an achromatic backdrop there is no complement, so it behaves as
        /// `nearest` for coloured text and adds no tint to grey text.
        case complementary
    }

    public var strategy: Strategy
    /// How far chroma may rise above the original, in OKLCH C. With 0, the text never becomes more
    /// saturated than it started, and grey text stays grey. The owner's +0.03 is about 1.5 JND: a
    /// tint you notice side by side, not a recolour.
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
    /// Keep saturated reds (OKLCH hue 345°–45°, C ≥ 0.1) inside the red band 350°–45°, so an error
    /// colour can turn crimson or vermilion but not orange (a warning) or magenta. Narrows the
    /// strategy's own range and never widens it.
    public var guardsSemanticRed: Bool
    /// Weight on closeness to the previous target when choosing among hue/chroma candidates. It
    /// stops two near-equal hue branches (leaning one way or the other) from alternating frame to frame.
    public var continuity: Double

    public init(
        strategy: Strategy, maxChromaGain: Double = 0.03, maxHueShift: Double = 45, advantage: Double = 0.03,
        chromaLossWeight: Double = 2, guardsSemanticRed: Bool = true, continuity: Double = 0.15
    ) {
        self.guardsSemanticRed = guardsSemanticRed
        self.chromaLossWeight = chromaLossWeight
        self.strategy = strategy
        self.maxChromaGain = maxChromaGain
        self.maxHueShift = maxHueShift
        self.advantage = advantage
        self.continuity = continuity
    }

    public static let lightnessOnly = HueShiftPolicy(strategy: .lightnessOnly)
    /// Owner decisions 2026-11-23: complementary, +0.03 chroma, 45° cap.
    public static let `default` = HueShiftPolicy(strategy: .complementary)

    static let redBand = (low: 350.0, high: 45.0)

    static func isSemanticRed(_ c: OKLCH) -> Bool { c.C >= 0.1 && (c.h >= 345 || c.h <= 45) }

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
        guard cMax > 0.01 - 1e-12, let yStar = boundaryLuminance(side, bg) else { return nil }

        let span = min(max(policy.maxHueShift, 0), 180)
        let bgHue = policy.strategy == .complementary ? Self.dominantHue(background) : nil
        var origin = original
        var range: ClosedRange<Double>
        if original.C < 0.01 {
            // Grey text has no hue to keep, so any tint is a free choice: the complement of the
            // backdrop, or none at all when the backdrop is grey too.
            switch policy.strategy {
            case .lightnessOnly: return nil
            case .nearest: range = -180...180
            case .complementary:
                guard let bgHue else { return nil }
                origin.h = (bgHue + 180).truncatingRemainder(dividingBy: 360)
                range = 0...0
            }
        } else {
            switch policy.strategy {
            case .lightnessOnly: return nil
            case .nearest: range = -span...span
            case .complementary:
                if let bgHue {
                    let away = signedHueDelta(from: bgHue, to: original.h)
                    let toComplement = min(180 - abs(away), span)
                    range = away >= 0 ? 0...toComplement : -toComplement...0
                } else {
                    range = -span...span
                }
            }
            if policy.guardsSemanticRed && HueShiftPolicy.isSemanticRed(original) {
                // min/max with 0 so a red just outside the band is never pushed into it, only held.
                let lo = max(range.lowerBound, min(0, signedHueDelta(from: original.h, to: HueShiftPolicy.redBand.low)))
                let hi = min(
                    range.upperBound, max(0, signedHueDelta(from: original.h, to: HueShiftPolicy.redBand.high)))
                range = lo <= hi ? lo...hi : 0...0
            }
        }

        func candidate(_ dh: Double, _ c: Double) -> (Candidate, Double)? {
            let h = (origin.h + dh).truncatingRemainder(dividingBy: 360)
            guard let cand = point(hue: h < 0 ? h + 360 : h, chroma: c, yStar: yStar, side: side, bg) else {
                return nil
            }
            var cost = policy.cost(from: original, to: cand.color.oklch)
            if let previous { cost += policy.continuity * cand.color.oklab.distance(to: previous) }
            return (cand, cost)
        }
        // Losing chroma is what the cost punishes, so at a given hue the best answer sits at the
        // most chroma that still fits the gamut at the lightness the target needs. Fixed chroma
        // levels kept landing inside the gamut instead of on its edge, and lost to lightness-only.
        func atEdge(_ dh: Double, upTo cap: Double) -> (Candidate, Double)? {
            if let hit = candidate(dh, cap) { return hit }
            var lo = 0.0, hi = cap
            guard candidate(dh, lo) != nil else { return nil }
            for _ in 0..<10 {
                let mid = (lo + hi) / 2
                if candidate(dh, mid) != nil { lo = mid } else { hi = mid }
            }
            return candidate(dh, lo)
        }
        func evaluate(_ dh: Double) -> (Candidate, Double)? {
            guard original.C > 0, cMax > original.C + 1e-9 else { return atEdge(dh, upTo: cMax) }
            guard let kept = atEdge(dh, upTo: original.C) else { return nil }
            // Where the gamut already binds below the original chroma, a higher cap finds the same edge.
            guard kept.0.color.oklch.C >= original.C - 1e-6, let gained = atEdge(dh, upTo: cMax) else { return kept }
            return gained.1 < kept.1 ? gained : kept
        }

        let width = range.upperBound - range.lowerBound
        let steps = max(Int((width / 15).rounded(.up)), 1)
        var best: (dh: Double, cand: Candidate, cost: Double)?
        for i in 0...steps {
            let dh = range.lowerBound + width * Double(i) / Double(steps)
            if let (cand, cost) = evaluate(dh), cost < (best?.cost ?? .infinity) { best = (dh, cand, cost) }
        }
        guard var b = best else { return nil }

        // Refine hue around the best grid point; the grid only has to land in the right basin.
        var step = width / Double(steps) / 2
        while step > 0.25 {
            var improved = false
            for dh in [b.dh - step, b.dh + step] where range.contains(dh) {
                if let (cand, cost) = evaluate(dh), cost < b.cost - 1e-9 {
                    b = (dh, cand, cost)
                    improved = true
                }
            }
            if !improved { step /= 2 }
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
        func lum(_ L: Double) -> Double { target.luminance(gamut.clamp(OKLCH(L: L, C: chroma, h: hue).rgb)) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<22 {
            let mid = (lo + hi) / 2
            if lum(mid) >= yStar { hi = mid } else { lo = mid }
        }
        let L = side == .lighter ? hi : lo
        let lch = OKLCH(L: L, C: chroma, h: hue)
        guard gamut.contains(lch) else { return nil }
        let color = lch.rgb
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
