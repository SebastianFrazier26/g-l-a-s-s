import CoreGraphics
import GlassContrast
import Testing

@testable import GlassOverlay

private func win(
    _ id: Int, _ owner: String, pid: Int, _ r: CGRect, layer: Int = 0, alpha: Double = 1, onScreen: Bool = true
) -> [String: Any] {
    [
        "kCGWindowNumber": id, "kCGWindowOwnerName": owner, "kCGWindowOwnerPID": pid, "kCGWindowLayer": layer,
        "kCGWindowIsOnscreen": onScreen, "kCGWindowAlpha": alpha,
        "kCGWindowBounds": ["X": r.minX, "Y": r.minY, "Width": r.width, "Height": r.height],
    ]
}

@Suite("Multi-display layout")
struct DisplayLayoutTests {
    // Built-in Retina display at the origin, 1x external to its right and slightly higher.
    let builtIn = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    let external = DisplayInfo(id: 2, frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440), scale: 1)

    @Test func picksDisplayWithLargestOverlap() {
        let mostlyExternal = CGRect(x: 1400, y: 100, width: 800, height: 600)
        #expect(DisplayLayout.best(for: mostlyExternal, among: [builtIn, external])?.id == 2)
        let mostlyBuiltIn = CGRect(x: 900, y: 100, width: 800, height: 600)
        #expect(DisplayLayout.best(for: mostlyBuiltIn, among: [builtIn, external])?.id == 1)
    }

    @Test func offscreenWindowHasNoDisplay() {
        #expect(DisplayLayout.best(for: CGRect(x: 9000, y: 9000, width: 10, height: 10), among: [builtIn]) == nil)
    }

    @Test func sourceRectIsDisplayLocalAndClipped() {
        let w = CGRect(x: 1400, y: 100, width: 800, height: 600)
        // Display-local: subtract the display origin; clip the part hanging over the left edge.
        #expect(DisplayLayout.sourceRect(window: w, display: external) == CGRect(x: 0, y: 300, width: 688, height: 600))
    }

    @Test func coverageIsTheCapturedPartOfTheWindow() {
        let w = CGRect(x: 1400, y: 100, width: 800, height: 600)
        let c = DisplayLayout.coverage(window: w, display: external)
        #expect(c == CGRect(x: 112, y: 0, width: 688, height: 600))
    }

    @Test func pixelSizeUsesThatDisplaysScaleAndNeverCollapses() {
        #expect(DisplayLayout.pixelSize(CGSize(width: 800, height: 600), scale: 2) == (1600, 1200))
        #expect(DisplayLayout.pixelSize(CGSize(width: 800, height: 600), scale: 1, factor: 0.5) == (400, 300))
        #expect(DisplayLayout.pixelSize(CGSize(width: 0.2, height: 0), scale: 1) == (2, 2))
    }
}

@Suite("Occlusion: menus, popovers and other windows in front of the target")
struct OcclusionTests {
    let target = CGRect(x: 100, y: 100, width: 600, height: 400)

    @Test func findsFrontWindowsThatOverlapInTargetLocalCoordinates() {
        let list = [
            win(50, "Notes", pid: 7, CGRect(x: 0, y: 0, width: 300, height: 300)),  // other app, overlaps
            win(51, "TextEdit", pid: 9, CGRect(x: 150, y: 120, width: 120, height: 200), layer: 101),  // its menu
            win(52, "Overlay", pid: 99, CGRect(x: 100, y: 100, width: 600, height: 400)),  // ourselves: ignored
            win(53, "Ghost", pid: 5, CGRect(x: 100, y: 100, width: 600, height: 400), alpha: 0),  // invisible
            win(54, "Far", pid: 6, CGRect(x: 2000, y: 0, width: 100, height: 100)),  // no overlap
            win(10, "TextEdit", pid: 9, target),  // the target itself
            win(60, "Behind", pid: 8, CGRect(x: 100, y: 100, width: 50, height: 50)),  // behind: ignored
        ]
        let rects = Occlusion.occluders(of: 10, in: list, ignoringPID: 99)
        #expect(rects == [CGRect(x: 0, y: 0, width: 200, height: 200), CGRect(x: 50, y: 20, width: 120, height: 200)])
    }

    @Test func overlayFallingBehindItsTargetIsDetected() {
        let f = CGRect(x: 0, y: 0, width: 100, height: 100)
        let ok = [win(52, "Overlay", pid: 99, f), win(50, "Notes", pid: 7, f), win(10, "TextEdit", pid: 9, f)]
        let raised = [win(10, "TextEdit", pid: 9, f), win(52, "Overlay", pid: 99, f)]  // after clicking the target
        #expect(Occlusion.isInFront(overlay: 52, of: 10, in: ok))
        #expect(!Occlusion.isInFront(overlay: 52, of: 10, in: raised))
        #expect(!Occlusion.isInFront(overlay: 52, of: 10, in: [win(10, "TextEdit", pid: 9, f)]))  // not on screen
    }

    @Test func missingTargetMeansNothingToCut() {
        #expect(Occlusion.occluders(of: 10, in: [win(1, "A", pid: 1, target)], ignoringPID: 99).isEmpty)
    }

    @Test func fullCoverageDetection() {
        let size = CGSize(width: 600, height: 400)
        #expect(Occlusion.isFullyCovered(size, by: [CGRect(x: -10, y: -10, width: 700, height: 500)]))
        #expect(
            Occlusion.isFullyCovered(
                size, by: [CGRect(x: 0, y: 0, width: 300, height: 400), CGRect(x: 300, y: 0, width: 300, height: 400)]))
        #expect(!Occlusion.isFullyCovered(size, by: [CGRect(x: 0, y: 0, width: 590, height: 400)]))
        #expect(!Occlusion.isFullyCovered(size, by: []))
    }
}

@MainActor
@Suite("Tracker: hide and show")
struct TrackerVisibilityTests {
    final class Source: @unchecked Sendable {
        var onScreen = true
        func list(_ id: CGWindowID) -> [[String: Any]] {
            [win(Int(id), "App", pid: 1, CGRect(x: 0, y: 0, width: 400, height: 300), onScreen: onScreen)]
        }
    }

    @Test func minimiseHidesAndRestoreReappears() {
        let src = Source()
        var events: [WindowTracker.Event] = []
        let t = WindowTracker(windowID: 3, source: src.list) { events.append($0) }
        t.poll()
        src.onScreen = false
        t.poll()
        t.poll()
        src.onScreen = true
        t.poll()
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(events == [.changed(frame), .hidden, .changed(frame)])
    }
}

@Suite("Stream restart policy")
struct RestartPolicyTests {
    @Test func backsOffExponentiallyThenGivesUp() {
        var p = RestartPolicy(base: 0.5, cap: 4, maxAttempts: 5)
        #expect(p.nextDelay() == 0.5)
        #expect(p.nextDelay() == 1)
        #expect(p.nextDelay() == 2)
        #expect(p.nextDelay() == 4)
        #expect(p.nextDelay() == 4)
        #expect(p.nextDelay() == nil)
    }

    @Test func resetAfterHealthyRunning() {
        var p = RestartPolicy(base: 1, cap: 8, maxAttempts: 2)
        _ = p.nextDelay()
        _ = p.nextDelay()
        p.reset()
        #expect(p.nextDelay() == 1)
    }
}

@Suite("Compositor: holes and partial backdrop coverage")
struct CompositorRobustnessTests {
    let compositor = GlassCompositor(softwareRendering: true)

    @Test func holesAreFullyTransparent() {
        var p = GlassParameters(mode: .uniform(alpha: 1))
        p.tintOpacity = 0
        let out = compositor.compose(
            backdrop: frame(40, 20, fill: .black).ciImage, window: frame(40, 20, fill: .white).ciImage,
            parameters: p, holes: [CGRect(x: 0, y: 0, width: 10, height: 20)])
        let img = compositor.renderRGBA(out, width: 40, height: 20)!
        #expect(img.pixel(5, 10).a == 0)
        #expect(img.pixel(30, 10).a == 255 && img.pixel(30, 10).r == 255)
    }

    @Test func partialBackdropIsPlacedNotStretched() {
        var p = GlassParameters(mode: .uniform(alpha: 0))
        p.tintOpacity = 0
        p.blurRadius = 0
        // Backdrop captured only for the right half (window hangs off its display on the left).
        let backdrop = frame(20, 20, fill: .white, rects: [(CGRect(x: 0, y: 0, width: 10, height: 20), .black)])
        let out = compositor.compose(
            backdrop: backdrop.ciImage, window: frame(40, 20, fill: .black).ciImage, parameters: p,
            backdropCoverage: CGRect(x: 20, y: 0, width: 20, height: 20))
        let img = compositor.renderRGBA(out, width: 40, height: 20)!
        #expect(img.pixel(25, 10).r < 10)  // black left half of the backdrop lands at x 20...30
        #expect(img.pixel(35, 10).r > 245)  // white right half at x 30...40
        #expect(img.pixel(5, 10).r < 10)  // uncovered area extends the nearest captured edge
    }
}
