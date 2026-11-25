import GlassContrast
import Testing

@testable import GlassOverlay

@Suite("Transparency setting and owner defaults")
struct SettingsTests {
    @Test func defaultIsKeyed() {
        #expect(TransparencySetting.default == .keyed)
        #expect(OwnerDefaults.transparency == .keyed)
    }

    @Test(arguments: [
        ("keyed", TransparencySetting.keyed), ("KEYED", .keyed), ("uniform", .uniform), ("Uniform", .uniform),
    ])
    func parsesModeNames(text: String, expected: TransparencySetting) {
        #expect(TransparencySetting(parsing: text) == expected)
    }

    @Test(arguments: ["", "key", "alpha", "uniform "])
    func rejectsUnknownModeNames(text: String) {
        #expect(TransparencySetting(parsing: text) == nil)
    }

    @Test func everyCaseRoundTripsThroughItsName() {
        for s in TransparencySetting.allCases { #expect(TransparencySetting(parsing: s.rawValue) == s) }
    }

    @Test func uniformMapsTransparencyToAlphaClampedToUnitRange() {
        #expect(TransparencySetting.uniform.windowMode() == .uniform(alpha: 1 - 0.7))
        #expect(TransparencySetting.uniform.windowMode(transparency: 0.25) == .uniform(alpha: 0.75))
        #expect(TransparencySetting.uniform.windowMode(transparency: 1.7) == .uniform(alpha: 0))
        #expect(TransparencySetting.uniform.windowMode(transparency: -2) == .uniform(alpha: 1))
    }

    @Test func keyedMapsToKeyColourOrPlaceholder() {
        let red = RGB(hex: 0xFF0000)
        guard case .keyed(let key, _, _, let contentAlpha) = TransparencySetting.keyed.windowMode(key: red) else {
            Issue.record("expected keyed mode")
            return
        }
        #expect(key == red)
        #expect(abs(contentAlpha - 0.8) < 1e-12)
        guard case .keyed(let placeholder, _, _, _) = TransparencySetting.keyed.windowMode() else {
            Issue.record("expected keyed mode")
            return
        }
        #expect(placeholder == .white)
    }

    @Test func pipelineOptionsCarryTheSettingAndFixedKey() {
        let key = RGB(hex: 0x202020)
        let keyed = OverlayPipeline.Options(transparency: .keyed, key: key)
        #expect(keyed.fixedKey == key)
        #expect(keyed.parameters.mode == TransparencySetting.keyed.windowMode(key: key))

        let look = GlassLook(transparency: 0.6, tintOpacity: 0.1, blurRadius: 3)
        let uniform = OverlayPipeline.Options(transparency: .uniform, look: look)
        #expect(uniform.fixedKey == nil)
        #expect(abs(uniform.parameters.mode.uniformAlpha! - 0.4) < 1e-12)
        #expect(uniform.parameters.tintOpacity == 0.1 && uniform.parameters.blurRadius == 3)
    }

    /// The modes differ in what the solver sees behind a glyph: uniform keeps part of the window's
    /// own background, keyed shows only glass. The text layer depends on this distinction.
    @Test func modesDifferInEffectiveBackground() {
        let backdrop = RGB(hex: 0x000000), windowBG = RGB(hex: 0xFFFFFF)
        let keyed = GlassParameters(mode: TransparencySetting.keyed.windowMode())
        let uniform = GlassParameters(mode: TransparencySetting.uniform.windowMode(transparency: 0.2))
        let kb = keyed.effectiveBackground(backdrop: backdrop, windowBackground: windowBG)
        let ub = uniform.effectiveBackground(backdrop: backdrop, windowBackground: windowBG)
        #expect(ub.r > kb.r + 0.3)
        let opaque = GlassParameters(mode: TransparencySetting.uniform.windowMode(transparency: 0))
        let ob = opaque.effectiveBackground(backdrop: backdrop, windowBackground: windowBG)
        #expect(abs(ob.r - windowBG.r) < 1e-9)
    }

    @Test func ownerDefaultsMatchDecisions() {
        #expect(OwnerDefaults.contrastTarget == .apca(60))
        #expect(OwnerDefaults.urgentOmega == nil)
        let o = OverlayPipeline.Options(transparency: .default)
        #expect(o.target == .apca(60))
        #expect(o.urgentOmega == nil)
    }
}

@Suite("Glass look (owner feedback 2026-11-24)")
struct GlassLookTests {
    @Test func defaultsAreLightFrosting() {
        let look = OwnerDefaults.look
        #expect(look == .default)
        #expect(look.tintOpacity == 0.04 && look.blurRadius == 6 && look.transparency == nil)
        let p = GlassParameters(mode: .uniform(alpha: 0))
        #expect(p.tintOpacity == look.tintOpacity && p.blurRadius == look.blurRadius)
    }

    @Test func initClampsToRanges() {
        let look = GlassLook(transparency: 3, tintOpacity: 0.9, blurRadius: -1)
        #expect(look.transparency == 1 && look.tintOpacity == 0.5 && look.blurRadius == 0)
    }

    @Test(arguments: [("0.3", 0.3), ("0", 0.0), ("1", 1.0)])
    func parsesValuesInRange(text: String, expected: Double) {
        #expect(GlassLook.parse(text, in: GlassLook.transparencyRange) == expected)
    }

    @Test(arguments: ["", "abc", "-0.1", "1.01", "nan", "inf"])
    func rejectsValuesOutsideRange(text: String) {
        #expect(GlassLook.parse(text, in: GlassLook.transparencyRange) == nil)
    }

    @Test func rejectsMissingValue() { #expect(GlassLook.parse(nil, in: GlassLook.blurRange) == nil) }

    @Test func keyedTransparencyLowersContentAlpha() {
        let p = GlassLook(transparency: 0.5).parameters(for: .keyed, key: .black)
        guard case .keyed(let key, _, _, let a) = p.mode else {
            Issue.record("expected keyed mode")
            return
        }
        #expect(key == .black && a == 0.5)
    }
}

extension WindowMode {
    var uniformAlpha: Double? {
        if case .uniform(let a) = self { return a }
        return nil
    }
}

@Suite("Hue-shift setting")
struct HueShiftSettingTests {
    @Test func ownerDefaultAllowsHueShift() {
        #expect(OwnerDefaults.hueShift.strategy == .complementary)
        let model = TextLayerModel(target: .apca(60), parameters: GlassParameters(mode: .uniform(alpha: 0.5)))
        #expect(model.hueShift == OwnerDefaults.hueShift)
    }

    @Test(arguments: [
        ("nearest", HueShiftPolicy.Strategy.nearest), ("Complementary", .complementary),
        ("lightness", .lightnessOnly), ("LIGHTNESS-ONLY", .lightnessOnly),
    ])
    func parsesStrategyNames(text: String, expected: HueShiftPolicy.Strategy) {
        #expect(HueShiftPolicy.Strategy(parsing: text) == expected)
    }

    @Test func rejectsUnknownStrategy() { #expect(HueShiftPolicy.Strategy(parsing: "hue") == nil) }
}
