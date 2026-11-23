import Foundation

/// WCAG 2.x relative luminance and contrast ratio (https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio).
public enum WCAG {
    public static func relativeLuminance(_ c: RGB) -> Double {
        let l = c.clamped().linear
        return 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b
    }

    public static func contrastRatio(_ x: RGB, _ y: RGB) -> Double {
        let a = relativeLuminance(x), b = relativeLuminance(y)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// APCA 0.0.98G-4g, matching the apca-w3 reference implementation (https://github.com/Myndex/apca-w3).
/// Note APCA deliberately uses a plain 2.4 exponent, not the piecewise sRGB curve.
public enum APCA {
    static let mainTRC = 2.4
    static let normBG = 0.56, normTXT = 0.57, revTXT = 0.62, revBG = 0.65
    static let blkThrs = 0.022, blkClmp = 1.414
    static let scale = 1.14, loOffset = 0.027, loClip = 0.1, deltaYmin = 0.0005

    public static func screenLuminance(_ c: RGB) -> Double {
        let k = c.clamped()
        return 0.2126729 * pow(k.r, mainTRC) + 0.7151522 * pow(k.g, mainTRC) + 0.0721750 * pow(k.b, mainTRC)
    }

    /// Signed Lc: positive for dark text on light background, negative for light on dark.
    public static func lightnessContrast(text: RGB, background: RGB) -> Double {
        var yt = screenLuminance(text), yb = screenLuminance(background)
        yt = yt > blkThrs ? yt : yt + pow(blkThrs - yt, blkClmp)
        yb = yb > blkThrs ? yb : yb + pow(blkThrs - yb, blkClmp)
        if abs(yb - yt) < deltaYmin { return 0 }
        if yb > yt {
            let sapc = (pow(yb, normBG) - pow(yt, normTXT)) * scale
            return sapc < loClip ? 0 : (sapc - loOffset) * 100
        } else {
            let sapc = (pow(yb, revBG) - pow(yt, revTXT)) * scale
            return sapc > -loClip ? 0 : (sapc + loOffset) * 100
        }
    }
}

/// What "readable" means. APCA thresholds (|Lc|): 90 preferred body text, 75 minimum body text,
/// 60 minimum for other content text, 45 large/bold headlines, 30 non-text. WCAG: 4.5 AA, 7 AAA, 3 large.
public enum ContrastTarget: Hashable, Sendable {
    case apca(Double)
    case wcag(Double)

    public var threshold: Double {
        switch self {
        case .apca(let t), .wcag(let t): t
        }
    }

    /// Polarity-agnostic score on the target's own scale (|Lc| or ratio).
    public func score(text: RGB, background: RGB) -> Double {
        switch self {
        case .apca: abs(APCA.lightnessContrast(text: text, background: background))
        case .wcag: WCAG.contrastRatio(text, background)
        }
    }

    public func isMet(text: RGB, background: RGB) -> Bool {
        score(text: text, background: background) >= threshold
    }

    /// Luminance the metric itself uses, so the solver orders backgrounds the same way it scores them.
    func luminance(_ c: RGB) -> Double {
        switch self {
        case .apca: APCA.screenLuminance(c)
        case .wcag: WCAG.relativeLuminance(c)
        }
    }
}
