/// A translucent veil drawn between the background and the text (black under light text, white
/// under dark text). Used only when no text colour alone can reach the target, typically when the
/// background behind one line spans both very dark and very light regions.
public struct ScrimResult: Sendable, Equatable {
    public let scrim: RGB
    public let opacity: Double
    public let solution: ContrastSolution

    public func apply(to background: RGB) -> RGB { Self.blend(background, over: scrim, opacity: opacity) }

    /// Source-over in linear light, which is how the compositor blends translucent layers.
    public static func blend(_ background: RGB, over scrim: RGB, opacity: Double) -> RGB {
        let b = background.linear, s = scrim.linear, a = min(max(opacity, 0), 1)
        return LinearRGB(r: b.r + (s.r - b.r) * a, g: b.g + (s.g - b.g) * a, b: b.b + (s.b - b.b) * a)
            .encoded.clamped()
    }
}

extension ContrastSolver {
    /// Text colour first, scrim only if needed, and then the faintest scrim that works.
    /// `maxOpacity` keeps the glass recognisably glass; beyond it the result reports failure.
    public func solveWithScrim(
        text: RGB, background: BackgroundSample, preferred: Polarity? = nil, maxOpacity: Double = 0.85
    ) -> ScrimResult {
        let plain = solve(text: text, background: background, preferred: preferred)
        if plain.meetsTarget {
            return ScrimResult(scrim: plain.polarity == .lighter ? .black : .white, opacity: 0, solution: plain)
        }

        func attempt(_ side: Polarity, _ opacity: Double) -> ContrastSolution? {
            let scrim: RGB = side == .lighter ? .black : .white
            let veiled = BackgroundSample(
                colors: background.colors.map { ScrimResult.blend($0, over: scrim, opacity: opacity) },
                weights: background.weights)
            let s = solve(text: text, background: veiled, preferred: side)
            return s.meetsTarget && s.polarity == side ? s : nil
        }

        var best: ScrimResult?
        var bestCost = Double.infinity
        for side in [Polarity.lighter, .darker] {
            guard attempt(side, maxOpacity) != nil else { continue }
            var lo = 0.0, hi = maxOpacity
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if attempt(side, mid) != nil { hi = mid } else { lo = mid }
            }
            guard let sol = attempt(side, hi) else { continue }
            // Same idea as polarity hysteresis: don't swap a black veil for a white one over a hair.
            let cost = hi - (side == preferred ? 0.05 : 0)
            if cost < bestCost {
                bestCost = cost
                best = ScrimResult(scrim: side == .lighter ? .black : .white, opacity: hi, solution: sol)
            }
        }
        if let best { return best }

        let side = plain.polarity
        let scrim: RGB = side == .lighter ? .black : .white
        let veiled = BackgroundSample(
            colors: background.colors.map { ScrimResult.blend($0, over: scrim, opacity: maxOpacity) },
            weights: background.weights)
        return ScrimResult(
            scrim: scrim, opacity: maxOpacity, solution: solve(text: text, background: veiled, preferred: side))
    }
}

extension RGB {
    public static let black = RGB(r: 0, g: 0, b: 0)
    public static let white = RGB(r: 1, g: 1, b: 1)
}
