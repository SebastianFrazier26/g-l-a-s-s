import Foundation

/// Critically damped spring in OKLab, stepped with the closed-form solution so it is exact and
/// stable at any frame interval (a dropped frame or a 10 s stall can't make it overshoot or explode).
/// Chosen over exponential easing because it starts with zero velocity: a retarget mid-transition
/// bends the path smoothly instead of kinking, which reads as calmer on text.
public struct SpringSmoother: Sendable {
    public private(set) var position: OKLab
    private var velocity: (L: Double, a: Double, b: Double) = (0, 0, 0)
    /// Angular frequency (rad/s). Settling to within 1% takes about 6.6 / omega seconds.
    public var omega: Double

    public init(initial: OKLab, omega: Double) {
        position = initial
        self.omega = omega
    }

    public mutating func step(toward target: OKLab, dt: Double) -> OKLab {
        let e = exp(-omega * dt)
        func axis(_ x: Double, _ v: Double, _ t: Double) -> (Double, Double) {
            let d = x - t
            let k = v + omega * d
            return (t + (d + k * dt) * e, (v - omega * k * dt) * e)
        }
        let (l, vl) = axis(position.L, velocity.L, target.L)
        let (a, va) = axis(position.a, velocity.a, target.a)
        let (b, vb) = axis(position.b, velocity.b, target.b)
        position = OKLab(L: l, a: a, b: b)
        velocity = (vl, va, vb)
        return position
    }
}

/// Solver + spring: feed it the background behind the text every frame, get back the colour to draw.
///
/// Two layers of hysteresis keep it from flickering on noisy, fast-changing backgrounds:
/// 1. Schmitt-trigger contrast: it solves for `threshold × (1 + headroom)` but only re-solves when
///    the current target drops below the bare threshold or the ideal colour moves more than
///    `deadband` (ΔE_OK; 0.02 ≈ one just-noticeable difference).
/// 2. The solver's polarity hysteresis, so near-equal light/dark choices don't alternate.
///
/// With `allowScrim`, lines that no text colour can rescue get a translucent veil (see `ScrimResult`)
/// whose opacity and colour are eased by their own springs, so the veil fades rather than pops.
public struct AdaptiveTextColor: Sendable {
    public var original: RGB
    public private(set) var solver: ContrastSolver
    public var headroom: Double
    public var deadband: Double
    public var allowScrim: Bool
    public private(set) var target: RGB
    public private(set) var polarity: Polarity?
    public private(set) var current: RGB
    public private(set) var targetScrimOpacity: Double = 0
    public private(set) var targetScrim: RGB = .black
    public private(set) var scrimOpacity: Double = 0
    public private(set) var scrim: RGB = .black
    private var spring: SpringSmoother
    private var scrimColorSpring: SpringSmoother
    private var scrimOpacitySpring: SpringSmoother

    public init(
        original: RGB, solver: ContrastSolver, omega: Double = 12, headroom: Double = 0.05, deadband: Double = 0.02,
        allowScrim: Bool = false
    ) {
        self.original = original
        self.solver = solver
        self.headroom = headroom
        self.deadband = deadband
        self.allowScrim = allowScrim
        target = original
        current = original
        spring = SpringSmoother(initial: original.oklab, omega: omega)
        scrimColorSpring = SpringSmoother(initial: RGB.black.oklab, omega: omega)
        scrimOpacitySpring = SpringSmoother(initial: OKLab(L: 0, a: 0, b: 0), omega: omega)
    }

    public var omega: Double {
        get { spring.omega }
        set {
            spring.omega = newValue
            scrimColorSpring.omega = newValue
            scrimOpacitySpring.omega = newValue
        }
    }

    public mutating func update(background: BackgroundSample, dt: Double) -> RGB {
        let veiledNow = veil(background, targetScrim, targetScrimOpacity)
        let violated = solver.worstCase(text: target, background: veiledNow) < solver.target.threshold
        var aiming = solver
        aiming.target = solver.target.raised(by: headroom)

        var ideal = aiming.solve(text: original, background: background, preferred: polarity)
        var idealScrim = (color: targetScrim, opacity: 0.0)
        if !ideal.meetsTarget && allowScrim {
            var r = aiming.solveWithScrim(text: original, background: background, preferred: polarity)
            if !r.solution.meetsTarget {
                r = solver.solveWithScrim(text: original, background: background, preferred: polarity)
            }
            ideal = r.solution
            idealScrim = (r.scrim, r.opacity)
        } else if !ideal.meetsTarget {
            ideal = solver.solve(text: original, background: background, preferred: polarity)
        }

        let colourMoved = ideal.color.oklab.distance(to: target.oklab) > deadband
        let scrimMoved = abs(idealScrim.opacity - targetScrimOpacity) > 0.03
        if violated || polarity == nil || colourMoved || scrimMoved {
            target = ideal.color
            polarity = ideal.polarity
            targetScrimOpacity = idealScrim.opacity
            if idealScrim.opacity > 0 { targetScrim = idealScrim.color }
        }
        current = spring.step(toward: target.oklab, dt: dt).rgb.clamped()
        scrim = scrimColorSpring.step(toward: targetScrim.oklab, dt: dt).rgb.clamped()
        scrimOpacity = min(
            max(scrimOpacitySpring.step(toward: OKLab(L: targetScrimOpacity, a: 0, b: 0), dt: dt).L, 0), 1)
        return current
    }

    private func veil(_ bg: BackgroundSample, _ scrim: RGB, _ opacity: Double) -> BackgroundSample {
        guard opacity > 0 else { return bg }
        return BackgroundSample(
            colors: bg.colors.map { ScrimResult.blend($0, over: scrim, opacity: opacity) }, weights: bg.weights)
    }
}

extension ContrastTarget {
    func raised(by fraction: Double) -> ContrastTarget {
        switch self {
        case .apca(let t): .apca(t * (1 + fraction))
        // Ratios start at 1, so scale the distance above 1.
        case .wcag(let t): .wcag(1 + (t - 1) * (1 + fraction))
        }
    }
}
