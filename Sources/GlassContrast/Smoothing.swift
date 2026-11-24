import Foundation

/// Where a colour transition travels.
public enum InterpolationSpace: Sendable, Hashable {
    /// Straight line in OKLab. A large hue change cuts through the middle and passes near grey.
    case oklab
    /// L, C and h eased separately, hue along the shorter arc. Chroma holds through a hue change,
    /// so a hue-shifted retarget turns rather than fading out and back in.
    case oklch
}

/// Critically damped spring in OKLab or OKLCH, stepped with the closed-form solution so it is exact
/// and stable at any frame interval (a dropped frame or a 10 s stall can't make it overshoot or explode).
/// Chosen over exponential easing because it starts with zero velocity: a retarget mid-transition
/// bends the path smoothly instead of kinking, which reads as calmer on text.
public struct SpringSmoother: Sendable {
    public private(set) var position: OKLab
    public let space: InterpolationSpace
    /// Spring state: (L, a, b) for `.oklab`; (L, C, unwrapped hue in degrees) for `.oklch`.
    private var state: (Double, Double, Double)
    private var velocity: (Double, Double, Double) = (0, 0, 0)
    /// Angular frequency (rad/s). Settling to within 1% takes about 6.6 / omega seconds.
    public var omega: Double

    /// Below this chroma hue is treated as undefined (CSS Color 4's "powerless" hue).
    static let achromatic = 1e-4

    public init(initial: OKLab, omega: Double, space: InterpolationSpace = .oklab) {
        position = initial
        self.omega = omega
        self.space = space
        switch space {
        case .oklab: state = (initial.L, initial.a, initial.b)
        case .oklch:
            let p = initial.lch
            state = (p.L, p.C, p.h)
        }
    }

    public mutating func step(toward target: OKLab, dt: Double) -> OKLab {
        let goal: (Double, Double, Double)
        switch space {
        case .oklab: goal = (target.L, target.a, target.b)
        case .oklch:
            let t = target.lch
            // A grey end has no hue of its own, so borrow the other end's: chroma then fades without
            // the hue swinging, and a grey start takes on the target hue directly.
            if state.1 < Self.achromatic { state.2 = t.h }
            let h = t.C < Self.achromatic ? state.2 : state.2 + signedHueDelta(from: state.2, to: t.h)
            goal = (t.L, t.C, h)
        }
        let e = exp(-omega * dt)
        func axis(_ x: Double, _ v: Double, _ t: Double) -> (Double, Double) {
            let d = x - t
            let k = v + omega * d
            return (t + (d + k * dt) * e, (v - omega * k * dt) * e)
        }
        let (x, vx) = axis(state.0, velocity.0, goal.0)
        let (y, vy) = axis(state.1, velocity.1, goal.1)
        let (z, vz) = axis(state.2, velocity.2, goal.2)
        state = (x, y, z)
        velocity = (vx, vy, vz)
        switch space {
        case .oklab: position = OKLab(L: x, a: y, b: z)
        case .oklch:
            // Critically damped from rest can't overshoot, but a retarget mid-flight can dip chroma below 0.
            if state.1 < 0 { state.1 = 0 }
            state.2 = state.2.truncatingRemainder(dividingBy: 360)
            position = OKLCH(L: x, C: state.1, h: state.2 < 0 ? state.2 + 360 : state.2).lab
        }
        return position
    }
}

/// Solver + spring: feed it the background behind the text every frame, get back the colour to draw.
///
/// Two layers of hysteresis keep it from flickering on noisy, fast-changing backgrounds:
/// 1. Schmitt-trigger contrast: it solves for `threshold × (1 + headroom)` but only re-solves when
///    the current target drops below the bare threshold or the ideal colour moves more than
///    `deadband` (ΔE_OK; 0.02 ≈ one just-noticeable difference).
/// 2. The solver's polarity hysteresis, so near-equal light/dark choices don't alternate, and its
///    hue-shift hysteresis (`HueShiftPolicy.advantage`, `.continuity`), so lightness-only and
///    hue-shifted answers, or two hue branches, don't alternate either.
///
/// `urgentOmega` (draft of design question 3b, off by default): while the colour on screen fails
/// the target, ease at this faster rate; once readable, fall back to the calm `omega`. Readability
/// recovers quickly, and only cosmetic refinements stay slow.
///
/// With `allowScrim`, lines that no text colour can rescue get a translucent veil (see `ScrimResult`)
/// whose opacity and colour are eased by their own springs, so the veil fades rather than pops.
public struct AdaptiveTextColor: Sendable {
    public var original: RGB
    public private(set) var solver: ContrastSolver
    public var headroom: Double
    public var deadband: Double
    public var allowScrim: Bool
    public var urgentOmega: Double?
    public private(set) var target: RGB
    public private(set) var polarity: Polarity?
    public private(set) var hueShifted: Bool?
    public private(set) var current: RGB
    public private(set) var targetScrimOpacity: Double = 0
    public private(set) var targetScrim: RGB = .black
    public private(set) var scrimOpacity: Double = 0
    public private(set) var scrim: RGB = .black
    private var spring: SpringSmoother
    private var scrimColorSpring: SpringSmoother
    private var scrimOpacitySpring: SpringSmoother
    private var calmOmega: Double

    public init(
        original: RGB, solver: ContrastSolver, omega: Double = 12, headroom: Double = 0.05, deadband: Double = 0.02,
        allowScrim: Bool = false, urgentOmega: Double? = nil, interpolation: InterpolationSpace = .oklch
    ) {
        self.urgentOmega = urgentOmega
        calmOmega = omega
        self.original = original
        self.solver = solver
        self.headroom = headroom
        self.deadband = deadband
        self.allowScrim = allowScrim
        target = original
        current = original
        spring = SpringSmoother(initial: original.oklab, omega: omega, space: interpolation)
        scrimColorSpring = SpringSmoother(initial: RGB.black.oklab, omega: omega)
        scrimOpacitySpring = SpringSmoother(initial: OKLab(L: 0, a: 0, b: 0), omega: omega)
    }

    public var omega: Double {
        get { calmOmega }
        set { calmOmega = newValue }
    }

    /// True when the colour (and veil) currently on screen misses the target for this background.
    public func isDisplayedUnreadable(over background: BackgroundSample) -> Bool {
        solver.worstCase(text: current, background: veil(background, scrim, scrimOpacity)) < solver.target.threshold
    }

    public mutating func update(background: BackgroundSample, dt: Double) -> RGB {
        let veiledNow = veil(background, targetScrim, targetScrimOpacity)
        let violated = solver.worstCase(text: target, background: veiledNow) < solver.target.threshold
        var aiming = solver
        aiming.target = solver.target.raised(by: headroom)

        let last = polarity == nil ? nil : target
        var ideal = aiming.solve(
            text: original, background: background, preferred: polarity, preferredHueShift: hueShifted, previous: last)
        var idealScrim = (color: targetScrim, opacity: 0.0)
        if !ideal.meetsTarget && allowScrim {
            var r = aiming.solveWithScrim(
                text: original, background: background, preferred: polarity, preferredHueShift: hueShifted,
                previous: last)
            if !r.solution.meetsTarget {
                r = solver.solveWithScrim(
                    text: original, background: background, preferred: polarity, preferredHueShift: hueShifted,
                    previous: last)
            }
            ideal = r.solution
            idealScrim = (r.scrim, r.opacity)
        } else if !ideal.meetsTarget {
            ideal = solver.solve(
                text: original, background: background, preferred: polarity, preferredHueShift: hueShifted,
                previous: last)
        }

        let colourMoved = ideal.color.oklab.distance(to: target.oklab) > deadband
        let scrimMoved = abs(idealScrim.opacity - targetScrimOpacity) > 0.03
        if violated || polarity == nil || colourMoved || scrimMoved {
            target = ideal.color
            polarity = ideal.polarity
            hueShifted = ideal.hueShifted
            targetScrimOpacity = idealScrim.opacity
            if idealScrim.opacity > 0 { targetScrim = idealScrim.color }
        }
        let rate = urgentOmega.map { isDisplayedUnreadable(over: background) ? $0 : calmOmega } ?? calmOmega
        spring.omega = rate
        scrimColorSpring.omega = rate
        scrimOpacitySpring.omega = rate
        // Mid-transition points can leave the gamut (chroma held at a lightness that can't carry it);
        // reducing chroma keeps hue, where per-channel clipping would skew it.
        current = spring.step(toward: target.oklab, dt: dt).lch.gamutMapped().rgb.clamped()
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
