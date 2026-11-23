import Testing

@testable import GlassContrast

private func close(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

@Suite("WCAG 2 contrast ratio")
struct WCAGTests {
    @Test func blackOnWhiteIs21() {
        #expect(close(WCAG.contrastRatio(RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)), 21, 1e-9))
    }

    @Test func symmetric() {
        let a = RGB(hex: 0x336699), b = RGB(hex: 0xEEDDCC)
        #expect(WCAG.contrastRatio(a, b) == WCAG.contrastRatio(b, a))
    }

    @Test func sameColourIsOne() {
        #expect(close(WCAG.contrastRatio(RGB(hex: 0x808080), RGB(hex: 0x808080)), 1, 1e-12))
    }

    // #767676 is the well-known darkest grey that passes 4.5:1 on white; #777777 just fails.
    @Test func aaThresholdGreys() {
        #expect(close(WCAG.contrastRatio(RGB(hex: 0x767676), RGB(hex: 0xFFFFFF)), 4.54, 0.01))
        #expect(WCAG.contrastRatio(RGB(hex: 0x777777), RGB(hex: 0xFFFFFF)) < 4.5)
    }
}

@Suite("APCA 0.0.98G-4g (apca-w3)")
struct APCATests {
    // Expected values are the apca-w3 reference outputs; -68.541 also appears in the apca-w3 README.
    @Test(arguments: [
        (0x888888 as UInt32, 0xFFFFFF as UInt32, 63.056469930209424),
        (0xFFFFFF, 0x888888, -68.54146436644962),
        (0x000000, 0xAAAAAA, 58.146262578561334),
        (0xAAAAAA, 0x000000, -56.24113336839742),
        (0x000000, 0xFFFFFF, 106.04067321268862),
        (0xFFFFFF, 0x000000, -107.88473318309848),
    ])
    func referencePairs(text: UInt32, background: UInt32, expected: Double) {
        let lc = APCA.lightnessContrast(text: RGB(hex: text), background: RGB(hex: background))
        #expect(close(lc, expected, 1e-9))
    }

    @Test func nearIdenticalIsZero() {
        #expect(APCA.lightnessContrast(text: RGB(hex: 0x808080), background: RGB(hex: 0x808080)) == 0)
        #expect(APCA.lightnessContrast(text: RGB(hex: 0x808080), background: RGB(hex: 0x818181)) == 0)
    }

    @Test func polaritySign() {
        #expect(APCA.lightnessContrast(text: RGB(hex: 0x111111), background: RGB(hex: 0xEEEEEE)) > 0)
        #expect(APCA.lightnessContrast(text: RGB(hex: 0xEEEEEE), background: RGB(hex: 0x111111)) < 0)
    }
}

@Suite("ContrastTarget")
struct ContrastTargetTests {
    @Test func apcaUsesMagnitude() {
        let t = ContrastTarget.apca(60)
        #expect(t.isMet(text: RGB(hex: 0xFFFFFF), background: RGB(hex: 0x000000)))
        #expect(!t.isMet(text: RGB(hex: 0x888888), background: RGB(hex: 0x999999)))
    }

    @Test func wcagThreshold() {
        let t = ContrastTarget.wcag(4.5)
        #expect(t.isMet(text: RGB(hex: 0x767676), background: RGB(hex: 0xFFFFFF)))
        #expect(!t.isMet(text: RGB(hex: 0x777777), background: RGB(hex: 0xFFFFFF)))
    }
}
