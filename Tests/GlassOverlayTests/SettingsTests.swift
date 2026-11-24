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

    @Test func uniformMapsToAlphaClampedToUnitRange() {
        #expect(TransparencySetting.uniform.windowMode() == .uniform(alpha: TransparencySetting.defaultUniformAlpha))
        #expect(TransparencySetting.uniform.windowMode(uniformAlpha: 0.3) == .uniform(alpha: 0.3))
        #expect(TransparencySetting.uniform.windowMode(uniformAlpha: 1.7) == .uniform(alpha: 1))
        #expect(TransparencySetting.uniform.windowMode(uniformAlpha: -2) == .uniform(alpha: 0))
    }

    @Test func keyedMapsToKeyColourOrPlaceholder() {
        let red = RGB(hex: 0xFF0000)
        guard case .keyed(let key, _, _, let contentAlpha) = TransparencySetting.keyed.windowMode(key: red) else {
            Issue.record("expected keyed mode")
            return
        }
        #expect(key == red)
        #expect(contentAlpha == 1)
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

        let uniform = OverlayPipeline.Options(transparency: .uniform, uniformAlpha: 0.4)
        #expect(uniform.fixedKey == nil)
        #expect(uniform.parameters.mode == .uniform(alpha: 0.4))
    }

    /// The modes differ in what the solver sees behind a glyph: uniform keeps part of the window's
    /// own background, keyed shows only glass. The text layer depends on this distinction.
    @Test func modesDifferInEffectiveBackground() {
        let backdrop = RGB(hex: 0x000000), windowBG = RGB(hex: 0xFFFFFF)
        let keyed = GlassParameters(mode: TransparencySetting.keyed.windowMode())
        let uniform = GlassParameters(mode: TransparencySetting.uniform.windowMode(uniformAlpha: 0.8))
        let kb = keyed.effectiveBackground(backdrop: backdrop, windowBackground: windowBG)
        let ub = uniform.effectiveBackground(backdrop: backdrop, windowBackground: windowBG)
        #expect(ub.r > kb.r + 0.3)
        let opaque = GlassParameters(mode: TransparencySetting.uniform.windowMode(uniformAlpha: 1))
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
