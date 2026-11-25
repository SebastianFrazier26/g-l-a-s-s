import GlassContrast

/// User-selectable transparency. Owner decision 2026-11-23: offer both modes as a setting, with keyed
/// as the default because uniform alpha fades the window's own text along with its background.
public enum TransparencySetting: String, CaseIterable, Sendable {
    case keyed
    case uniform

    public static let `default`: TransparencySetting = .keyed

    /// Share of the window's own (non-key) pixels that gives way to glass, before any flag.
    /// Owner feedback 2026-11-24 ("more transparent, by a lot", DESIGN §6c): uniform went from a
    /// 0.55 copy to 0.3; keyed content went from solid to 80%. OCR'd text is redrawn opaque on top,
    /// so only icons, images and undetected text fade in keyed mode.
    public var defaultTransparency: Double {
        switch self {
        case .keyed: return 0.2
        case .uniform: return 0.7
        }
    }

    /// Accepts any letter case; nil for anything else, so a typo is reported instead of silently
    /// falling back to the default.
    public init?(parsing text: String) {
        self.init(rawValue: text.lowercased())
    }

    /// `transparency` nil means `defaultTransparency`; values are clamped to
    /// `GlassLook.transparencyRange`. `key` nil means "use the window's dominant colour", resolved
    /// later by `OverlayPipeline`.
    public func windowMode(transparency: Double? = nil, key: RGB? = nil) -> WindowMode {
        let opacity = 1 - GlassLook.transparencyRange.clamp(transparency ?? defaultTransparency)
        switch self {
        case .uniform:
            return .uniform(alpha: opacity)
        case .keyed:
            return .keyed(key: key ?? .white, tolerance: 0.06, softness: 0.12, contentAlpha: opacity)
        }
    }
}

/// Defaults fixed by owner decisions on 2026-11-23 (DESIGN §6b) and feedback on 2026-11-24 (§6c).
public enum OwnerDefaults {
    public static let contrastTarget: ContrastTarget = .apca(60)
    /// "Always smooth": urgent easing stays available behind a flag but is off by default.
    public static let urgentOmega: Double? = nil
    public static let transparency: TransparencySetting = .default
    /// Owner decision 2026-11-23: hue and chroma may move, not only lightness (DESIGN §6 item 2).
    public static let hueShift: HueShiftPolicy = .default
    /// Owner feedback 2026-11-24 (DESIGN §6c).
    public static let look: GlassLook = .default
}

/// How see-through the glass is. Owner feedback 2026-11-24: the first look (18% white tint, blur
/// sigma 24 px, opaque window content) read as a frosted panel, so the defaults keep only the
/// frosting text needs and leave legibility to the contrast engine and its scrim (DESIGN §6c).
public struct GlassLook: Sendable, Equatable {
    public static let transparencyRange = 0.0...1.0
    public static let tintRange = 0.0...0.5
    /// Gaussian sigma in window-capture pixels (2 px = 1 pt on Retina).
    public static let blurRange = 0.0...40.0
    public static let `default` = GlassLook()

    /// nil: the transparency mode's own default (`TransparencySetting.defaultTransparency`).
    public var transparency: Double?
    public var tintOpacity: Double
    public var blurRadius: Double

    public init(transparency: Double? = nil, tintOpacity: Double = 0.04, blurRadius: Double = 6) {
        self.transparency = transparency.map(Self.transparencyRange.clamp)
        self.tintOpacity = Self.tintRange.clamp(tintOpacity)
        self.blurRadius = Self.blurRange.clamp(blurRadius)
    }

    public func parameters(for mode: TransparencySetting, key: RGB? = nil) -> GlassParameters {
        var p = GlassParameters(mode: mode.windowMode(transparency: transparency, key: key))
        p.tintOpacity = tintOpacity
        p.blurRadius = blurRadius
        return p
    }

    /// A command-line value inside `range`; nil for non-numbers and out-of-range values, so a typo
    /// is reported rather than clamped into something the user didn't ask for.
    public static func parse(_ text: String?, in range: ClosedRange<Double>) -> Double? {
        guard let text, let v = Double(text), v.isFinite, range.contains(v) else { return nil }
        return v
    }
}

extension ClosedRange where Bound == Double {
    func clamp(_ v: Double) -> Double { Swift.min(Swift.max(v, lowerBound), upperBound) }
}

extension HueShiftPolicy.Strategy {
    /// Accepts any letter case; nil for anything else, matching `TransparencySetting(parsing:)`.
    public init?(parsing text: String) {
        switch text.lowercased() {
        case "lightness", "lightness-only": self = .lightnessOnly
        case "nearest": self = .nearest
        case "complementary": self = .complementary
        default: return nil
        }
    }
}

extension OverlayPipeline.Options {
    public init(transparency: TransparencySetting, look: GlassLook = .default, key: RGB? = nil) {
        self.init(parameters: look.parameters(for: transparency, key: key))
        fixedKey = key
    }
}
