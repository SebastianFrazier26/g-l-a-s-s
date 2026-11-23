/// Colours sampled from the region behind a piece of text, optionally weighted (e.g. by pixel count
/// or by distance from the glyph centre). A single solid colour is just a one-element sample.
public struct BackgroundSample: Sendable {
    public let colors: [RGB]
    public let weights: [Double]

    public init(colors: [RGB], weights: [Double]? = nil) {
        precondition(weights == nil || weights!.count == colors.count, "one weight per colour")
        self.colors = colors
        self.weights = weights ?? Array(repeating: 1, count: colors.count)
    }

    public static func uniform(_ c: RGB) -> BackgroundSample { BackgroundSample(colors: [c]) }

    /// The darkest and lightest backgrounds the text must survive. `coverage` is the weighted share
    /// of the distribution that must be satisfied: 0.95 ignores the darkest 5% when judging dark text
    /// and the lightest 5% when judging light text, so a few stray pixels don't force pure black/white.
    public func summary(coverage: Double, luminance: (RGB) -> Double = APCA.screenLuminance) -> Summary {
        guard !colors.isEmpty else {
            let grey = RGB(r: 0.5, g: 0.5, b: 0.5)
            return Summary(darkest: grey, lightest: grey)
        }
        let order = colors.indices.sorted { luminance(colors[$0]) < luminance(colors[$1]) }
        let total = weights.reduce(0, +)
        let tail = (1 - min(max(coverage, 0), 1)) * total

        func quantile(_ q: Double) -> RGB {
            var acc = 0.0
            for i in order {
                acc += weights[i]
                if acc > q + 1e-12 { return colors[i] }
            }
            return colors[order.last!]
        }
        // Lower quantile: first colour whose cumulative weight passes the tail; upper: mirror of that.
        let darkest = quantile(tail)
        var acc = 0.0
        var lightest = colors[order.last!]
        for i in order.reversed() {
            acc += weights[i]
            if acc > tail + 1e-12 {
                lightest = colors[i]
                break
            }
        }
        return Summary(darkest: darkest, lightest: lightest)
    }

    public struct Summary: Sendable, Equatable {
        public let darkest: RGB
        public let lightest: RGB
    }
}
