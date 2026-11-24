import GlassContrast
import Observation
import SwiftUI

/// Animated backdrop: vertical stripes whose OKLCH lightness sweeps dark ↔ light while hue drifts,
/// so the text behind the glass is forced through both polarities.
struct Backdrop {
    static let stripeCount = 48

    static func stripes(at t: Double) -> [RGB] {
        (0..<stripeCount).map { i in
            let x = Double(i) / Double(stripeCount - 1)
            let L = 0.5 + 0.45 * sin(t * 0.6 + x * 2.2)
            let h = (t * 25 + x * 120).truncatingRemainder(dividingBy: 360)
            return OKLCH(L: L, C: 0.14, h: h).gamutMapped().rgb.clamped()
        }
    }
}

/// The glass panel: a light tint over the (blurred) backdrop. Mixing in linear light mirrors how
/// a compositor blends; the solver sees this blended colour as the background behind the text.
struct GlassTint {
    var color = RGB(r: 1, g: 1, b: 1)
    var opacity = 0.18

    func over(_ bg: RGB) -> RGB {
        let a = bg.linear, t = color.linear
        return LinearRGB(
            r: a.r + (t.r - a.r) * opacity,
            g: a.g + (t.g - a.g) * opacity,
            b: a.b + (t.b - a.b) * opacity
        ).encoded.clamped()
    }
}

struct DemoLine: Identifiable {
    let id: Int
    let label: String
    let original: RGB
    let fontSize: CGFloat
    var adaptive: AdaptiveTextColor
}

@MainActor @Observable
final class DemoModel {
    private(set) var time: Double = 0
    private(set) var stripes: [RGB] = Backdrop.stripes(at: 0)
    private(set) var lines: [DemoLine]
    var adaptiveEnabled = true
    let tint = GlassTint()
    /// Horizontal span of the panel's text, as a fraction of the backdrop width.
    let textSpan: ClosedRange<Double> = 0.18...0.82

    init() {
        let solver = ContrastSolver(target: .apca(60))
        let specs: [(String, UInt32, CGFloat)] = [
            ("Liquid glass, readable text", 0x2D5BD8, 30),
            ("Brand orange stays colourful", 0xF08A24, 22),
            ("Quiet secondary grey label", 0x8A8A8A, 18),
            ("Original colour, never adapted", 0x2D5BD8, 16),
        ]
        lines = specs.enumerated().map { i, s in
            DemoLine(
                id: i, label: s.0, original: RGB(hex: s.1), fontSize: s.2,
                adaptive: AdaptiveTextColor(original: RGB(hex: s.1), solver: solver, allowScrim: true))
        }
    }

    func step(dt: Double) {
        time += dt
        stripes = Backdrop.stripes(at: time)
        let bg = backgroundBehindText()
        for i in lines.indices {
            _ = lines[i].adaptive.update(background: bg, dt: dt)
        }
    }

    func backgroundBehindText() -> BackgroundSample {
        let n = stripes.count
        let lo = Int(textSpan.lowerBound * Double(n - 1)), hi = Int(textSpan.upperBound * Double(n - 1))
        return BackgroundSample(colors: stripes[lo...hi].map(tint.over))
    }

    func displayColor(for line: DemoLine) -> RGB {
        // The last line is the control: it always shows the unadapted original.
        (adaptiveEnabled && line.id != lines.count - 1) ? line.adaptive.current : line.original
    }

    func scrimOpacity(for line: DemoLine) -> Double {
        (adaptiveEnabled && line.id != lines.count - 1) ? line.adaptive.scrimOpacity : 0
    }

    func worstCaseLc(for line: DemoLine) -> Double {
        let bg = backgroundBehindText()
        let veiled = BackgroundSample(
            colors: bg.colors.map {
                ScrimResult.blend($0, over: line.adaptive.scrim, opacity: scrimOpacity(for: line))
            })
        return ContrastSolver(target: .apca(60), coverage: 1).worstCase(
            text: displayColor(for: line), background: veiled)
    }
}

extension Color {
    init(_ c: RGB) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1) }
}
