import GlassContrast

/// User-selectable transparency. Owner decision 2026-11-23: offer both modes as a setting, with keyed
/// as the default because uniform alpha fades the window's own text along with its background.
public enum TransparencySetting: String, CaseIterable, Sendable {
    case keyed
    case uniform

    public static let `default`: TransparencySetting = .keyed
    public static let defaultUniformAlpha = 0.55

    /// Accepts any letter case; nil for anything else, so a typo is reported instead of silently
    /// falling back to the default.
    public init?(parsing text: String) {
        self.init(rawValue: text.lowercased())
    }

    /// `key` nil means "use the window's dominant colour", resolved later by `OverlayPipeline`.
    public func windowMode(uniformAlpha: Double = defaultUniformAlpha, key: RGB? = nil) -> WindowMode {
        switch self {
        case .uniform:
            return .uniform(alpha: min(max(uniformAlpha, 0), 1))
        case .keyed:
            return .keyed(key: key ?? .white, tolerance: 0.06, softness: 0.12, contentAlpha: 1)
        }
    }
}

/// Defaults fixed by owner decisions on 2026-11-23 (DESIGN §6b).
public enum OwnerDefaults {
    public static let contrastTarget: ContrastTarget = .apca(60)
    /// "Always smooth": urgent easing stays available behind a flag but is off by default.
    public static let urgentOmega: Double? = nil
    public static let transparency: TransparencySetting = .default
}

extension OverlayPipeline.Options {
    public init(
        transparency: TransparencySetting, uniformAlpha: Double = TransparencySetting.defaultUniformAlpha,
        key: RGB? = nil
    ) {
        self.init(parameters: GlassParameters(mode: transparency.windowMode(uniformAlpha: uniformAlpha, key: key)))
        fixedKey = key
    }
}
