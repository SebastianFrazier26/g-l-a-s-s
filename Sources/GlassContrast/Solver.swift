/// Which side of the background the text sits on.
public enum Polarity: Sendable, Hashable {
    case lighter
    case darker
}

public struct ContrastSolution: Sendable, Equatable {
    public let color: RGB
    public let polarity: Polarity
    /// Worst-case score across the covered background, on the target's own scale.
    public let contrast: Double
    public let meetsTarget: Bool
    public let changed: Bool
    /// True when hue or chroma moved by choice (see `HueShiftPolicy`), not just lightness.
    public let hueShifted: Bool
}

/// Picks the text colour closest to the original (in OKLab) that meets a contrast target against
/// a background distribution.
///
/// Colour-theory choices, and what was rejected:
/// - First search in OKLCH holding hue fixed, moving lightness only. OKLCH hue is perceptually
///   stable under lightness change; HSL/HSV lightening visibly shifts hue (blue drifts purple).
/// - Chroma is kept where the sRGB gamut allows and reduced only when the new lightness can't hold
///   it. Near L = 0 or 1 the gamut collapses, so the search naturally ends at near-black/near-white:
///   that *is* the fallback, no special case needed.
/// - Then, under `hueShift`, search hue and chroma too, and take that result only if it is closer
///   to the original by `hueShift.advantage`. Lightness-only stays the default answer.
/// - Both polarities are tried and the smaller perceptual change wins, rather than always flipping
///   to white/black, so a brand colour stays recognisably itself whenever the background allows.
public struct ContrastSolver: Sendable {
    public var target: ContrastTarget
    public var coverage: Double
    /// ΔE_OK advantage the non-preferred polarity must have before the solver switches to it.
    public var polarityHysteresis: Double
    public var hueShift: HueShiftPolicy
    /// Gamut of the display the text is drawn on; results never leave it.
    public var gamut: ColorGamut

    public init(
        target: ContrastTarget, coverage: Double = 0.95, polarityHysteresis: Double = 0.05,
        hueShift: HueShiftPolicy = .default, gamut: ColorGamut = .sRGB
    ) {
        self.gamut = gamut
        self.target = target
        self.coverage = coverage
        self.polarityHysteresis = polarityHysteresis
        self.hueShift = hueShift
    }

    /// `preferredHueShift` and `previous` are the last solution's mode and colour. They add
    /// hysteresis, so the answer doesn't flip between lightness-only and hue-shifted on noise.
    public func solve(
        text: RGB, background: BackgroundSample, preferred: Polarity? = nil, preferredHueShift: Bool? = nil,
        previous: RGB? = nil
    ) -> ContrastSolution {
        let original = gamut.clamp(text)
        let bg = background.summary(coverage: coverage, luminance: target.luminance)

        let (startScore, startSide) = worstCase(original, bg)
        if startScore >= target.threshold {
            return ContrastSolution(
                color: original, polarity: startSide, contrast: startScore, meetsTarget: true, changed: false,
                hueShifted: false)
        }

        let lch = original.oklch
        let lab = original.oklab
        func shifted(_ plain: Candidate) -> Candidate {
            guard plain.feasible, hueShift.strategy != .lightnessOnly else { return plain }
            if lch.C < 0.01 && hueShift.tintsGreyText {
                return greyTint(toward: plain.polarity, bg, background: background) ?? plain
            }
            let plainCost = hueShift.cost(from: lch, to: plain.color.oklch)
            // Inside the hysteresis band the previous mode keeps winning, in both directions.
            let margin = preferredHueShift == true ? -hueShift.advantage : hueShift.advantage
            guard plainCost > margin,
                let alt = shiftSearch(
                    from: lch, toward: plain.polarity, bg, background: background, previous: previous?.oklab)
            else { return plain }
            return hueShift.cost(from: lch, to: alt.color.oklch) < plainCost - margin ? alt : plain
        }
        let light = shifted(search(from: lch, toward: .lighter, bg))
        let dark = shifted(search(from: lch, toward: .darker, bg))

        let chosen: Candidate
        switch (light.feasible, dark.feasible) {
        case (true, false): chosen = light
        case (false, true): chosen = dark
        case (true, true):
            var costLight = light.color.oklab.distance(to: lab)
            var costDark = dark.color.oklab.distance(to: lab)
            if preferred == .lighter { costLight -= polarityHysteresis }
            if preferred == .darker { costDark -= polarityHysteresis }
            chosen = costLight <= costDark ? light : dark
        case (false, false):
            // Nothing works: give the strongest extreme and let the caller add a backing scrim.
            let margin = 0.05 * target.threshold
            var sLight = light.score, sDark = dark.score
            if preferred == .lighter { sLight += margin }
            if preferred == .darker { sDark += margin }
            chosen = sLight >= sDark ? light : dark
        }
        return ContrastSolution(
            color: chosen.color, polarity: chosen.polarity, contrast: chosen.score,
            meetsTarget: chosen.feasible, changed: true, hueShifted: chosen.hueShifted)
    }

    /// Worst-case score of `text` over the covered background. Text whose luminance falls inside the
    /// background's range scores 0: some background pixel matches it.
    public func worstCase(text: RGB, background: BackgroundSample) -> Double {
        worstCase(gamut.clamp(text), background.summary(coverage: coverage, luminance: target.luminance)).0
    }

    func worstCase(_ text: RGB, _ bg: BackgroundSample.Summary) -> (Double, Polarity) {
        let y = target.luminance(text)
        if y > target.luminance(bg.lightest) {
            return (target.score(text: text, background: bg.lightest), .lighter)
        }
        if y < target.luminance(bg.darkest) {
            return (target.score(text: text, background: bg.darkest), .darker)
        }
        return (0, y >= target.luminance(bg.darkest) * 0.5 + target.luminance(bg.lightest) * 0.5 ? .lighter : .darker)
    }

    struct Candidate {
        let color: RGB
        let polarity: Polarity
        let score: Double
        let feasible: Bool
        var hueShifted = false
    }

    private func search(from lch: OKLCH, toward side: Polarity, _ bg: BackgroundSample.Summary) -> Candidate {
        func color(at L: Double) -> RGB {
            gamut.clamp(OKLCH(L: L, C: min(lch.C, Gamut.maxChroma(lightness: L, hue: lch.h, in: gamut)), h: lch.h).rgb)
        }
        func score(_ c: RGB) -> Double {
            let (s, p) = worstCase(c, bg)
            return p == side ? s : 0
        }
        let end = side == .lighter ? 1.0 : 0.0
        let extreme = color(at: end)
        let extremeScore = score(extreme)
        guard extremeScore >= target.threshold else {
            return Candidate(color: extreme, polarity: side, score: extremeScore, feasible: false)
        }
        // Invariant: `hi` always satisfies the target, so whatever we return is verified, even if
        // contrast is not perfectly monotone in L once chroma clamping kicks in.
        var lo = lch.L, hi = end
        var best = extreme, bestScore = extremeScore
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            let c = color(at: mid)
            let s = score(c)
            if s >= target.threshold {
                hi = mid
                best = c
                bestScore = s
            } else {
                lo = mid
            }
        }
        return Candidate(color: best, polarity: side, score: bestScore, feasible: true)
    }
}
