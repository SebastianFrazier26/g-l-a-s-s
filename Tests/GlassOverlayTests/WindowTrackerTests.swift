import CoreGraphics
import Testing

@testable import GlassOverlay

private func info(
    id: Int, owner: String, pid: Int = 42, x: Double, y: Double, w: Double, h: Double, layer: Int = 0,
    onScreen: Bool = true
) -> [String: Any] {
    [
        "kCGWindowNumber": id, "kCGWindowOwnerName": owner, "kCGWindowOwnerPID": pid, "kCGWindowLayer": layer,
        "kCGWindowIsOnscreen": onScreen,
        "kCGWindowBounds": ["X": x, "Y": y, "Width": w, "Height": h],
    ]
}

@Suite("Coordinate conversion")
struct GeometryTests {
    @Test func cgTopLeftToAppKitBottomLeft() {
        // Primary display 1000 pt tall; a window 100 pt from the top, 300 tall, sits 600 from the bottom.
        let r = ScreenGeometry.appKitFrame(fromCG: CGRect(x: 50, y: 100, width: 400, height: 300), primaryHeight: 1000)
        #expect(r == CGRect(x: 50, y: 600, width: 400, height: 300))
    }

    @Test func roundTrip() {
        let cg = CGRect(x: -1200, y: -80, width: 640, height: 480)  // display left of and above primary
        let back = ScreenGeometry.cgFrame(
            fromAppKit: ScreenGeometry.appKitFrame(fromCG: cg, primaryHeight: 900),
            primaryHeight: 900)
        #expect(back == cg)
    }
}

@Suite("Window list parsing")
struct WindowListTests {
    @Test func parsesSnapshot() {
        let s = WindowSnapshot(info: info(id: 7, owner: "Safari", x: 10, y: 20, w: 300, h: 200))
        #expect(s?.id == 7 && s?.ownerName == "Safari" && s?.frame == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test func rejectsMalformed() {
        #expect(WindowSnapshot(info: ["kCGWindowNumber": 1]) == nil)
    }

    @Test func findsFrontmostNormalWindowOfApp() {
        let list = [
            info(id: 1, owner: "Dock", x: 0, y: 0, w: 10, h: 10, layer: 20),
            info(id: 2, owner: "Safari", x: 0, y: 0, w: 5, h: 5, layer: 3),  // a Safari panel, not a window
            info(id: 3, owner: "Safari", x: 0, y: 0, w: 800, h: 600),
            info(id: 4, owner: "Safari", x: 0, y: 0, w: 800, h: 600),
        ]
        #expect(WindowList.frontmostWindow(ownedBy: "Safari", in: list)?.id == 3)
        #expect(WindowList.frontmostWindow(ownedBy: "Notes", in: list) == nil)
    }

    @Test func skipsTinyAndOffscreenWindows() {
        let list = [
            info(id: 5, owner: "Mail", x: 0, y: 0, w: 1, h: 1),
            info(id: 6, owner: "Mail", x: 0, y: 0, w: 900, h: 700, onScreen: false),
            info(id: 8, owner: "Mail", x: 0, y: 0, w: 900, h: 700),
        ]
        #expect(WindowList.frontmostWindow(ownedBy: "Mail", in: list)?.id == 8)
    }
}

@MainActor
@Suite("Window tracker")
struct WindowTrackerTests {
    final class FakeSource: @unchecked Sendable {
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 400, height: 300)
        func list(_ id: CGWindowID) -> [[String: Any]] {
            guard let f = frame else { return [] }
            return [info(id: Int(id), owner: "App", x: f.minX, y: f.minY, w: f.width, h: f.height)]
        }
    }

    @Test func reportsMovesAndResizesOnce() {
        let src = FakeSource()
        var events: [WindowTracker.Event] = []
        let t = WindowTracker(windowID: 9, source: src.list) { events.append($0) }
        t.poll()
        #expect(events == [.changed(CGRect(x: 0, y: 0, width: 400, height: 300))])
        t.poll()
        #expect(events.count == 1)  // unchanged: no event
        src.frame = CGRect(x: 25, y: 0, width: 400, height: 300)
        t.poll()
        src.frame = CGRect(x: 25, y: 0, width: 500, height: 320)
        t.poll()
        #expect(events.count == 3)
        #expect(events.last == .changed(CGRect(x: 25, y: 0, width: 500, height: 320)))
    }

    @Test func reportsCloseOnceAndStops() {
        let src = FakeSource()
        var events: [WindowTracker.Event] = []
        let t = WindowTracker(windowID: 9, source: src.list) { events.append($0) }
        t.poll()
        src.frame = nil
        t.poll()
        t.poll()
        #expect(events.last == .closed)
        #expect(events.filter { $0 == .closed }.count == 1)
    }
}

@MainActor
@Suite("Overlay window")
struct OverlayWindowTests {
    @Test func isClickThroughTransparentAndBorderless() {
        let w = OverlayWindow(cgFrame: CGRect(x: 100, y: 100, width: 300, height: 200))
        #expect(w.ignoresMouseEvents)
        #expect(!w.isOpaque && w.backgroundColor == .clear)
        #expect(w.styleMask == .borderless)
        #expect(w.frame.size == CGSize(width: 300, height: 200))
        #expect(w.sharingType == .none)
    }
}
