import AppKit
import CoreGraphics

/// CGWindowList / ScreenCaptureKit use a top-left origin at the primary display's top-left corner;
/// AppKit uses a bottom-left origin at the primary display's bottom-left corner.
public enum ScreenGeometry {
    public static func appKitFrame(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func cgFrame(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    @MainActor public static var primaryHeight: CGFloat {
        // screens[0] is always the menu-bar display, which defines the global origin.
        NSScreen.screens.first?.frame.height ?? 0
    }
}

public struct WindowSnapshot: Equatable, Sendable {
    public let id: CGWindowID
    public let ownerName: String
    public let ownerPID: pid_t
    public let frame: CGRect
    public let layer: Int
    public let isOnScreen: Bool

    /// Parses one CGWindowListCopyWindowInfo entry. Uses only keys that are readable *without*
    /// Screen Recording (window titles are not, so they are deliberately not used).
    public init?(info: [String: Any]) {
        guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
                ?? Self.rect(from: boundsDict)
        else { return nil }
        self.id = id
        ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
        ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        self.frame = frame
        layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    }

    private static func rect(from d: [String: Any]) -> CGRect? {
        guard let x = d["X"] as? Double, let y = d["Y"] as? Double, let w = d["Width"] as? Double,
            let h = d["Height"] as? Double
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

public enum WindowList {
    public typealias Source = (CGWindowID) -> [[String: Any]]

    /// The real source: one window by id. Bounds and owner need no permission at all.
    public static func system(_ id: CGWindowID) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]) ?? []
    }

    public static func allOnScreen() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
    }

    /// The list is front-to-back, so the first normal-layer, visible, non-trivial window wins.
    public static func frontmostWindow(ownedBy app: String, in list: [[String: Any]]) -> WindowSnapshot? {
        list.lazy.compactMap(WindowSnapshot.init(info:)).first {
            $0.ownerName == app && $0.layer == 0 && $0.isOnScreen && $0.frame.width > 40 && $0.frame.height > 40
        }
    }
}

/// Follows one window by polling CGWindowList.
///
/// Polling was chosen over AXObserver move/resize notifications: it needs no permission (AX needs
/// Accessibility), and mapping an AX window to a CGWindowID needs the private
/// `_AXUIElementGetWindow`. Cost: one WindowServer round-trip per tick.
///
/// Adaptive rate (owner decision 2026-11-23): `activeHz` while the frame is changing, so a drag is
/// followed within ~1 frame; `idleHz` once it has been still for `settleTime`. At 60 Hz the poll cost
/// ~5% of a core per window plus WindowServer load; the price is up to 1/idleHz of lag on the
/// first frame of a drag.
@MainActor
public final class WindowTracker {
    public enum Event: Equatable, Sendable {
        case changed(CGRect)
        /// Minimised, on another Space, or app hidden: pause and hide the overlay, keep tracking.
        case hidden
        case closed
    }

    public let windowID: CGWindowID
    private let source: WindowList.Source
    private let onEvent: (Event) -> Void
    private var last: CGRect?
    private var closed = false
    private var hidden = false
    private var timer: Timer?
    private var activeHz = 60.0
    private var idleHz = 10.0
    private var settleTime = 0.5
    private var stillPolls = 0
    public private(set) var currentHz = 0.0
    private var started = false

    public init(
        windowID: CGWindowID, source: @escaping WindowList.Source = WindowList.system,
        onEvent: @escaping (Event) -> Void
    ) {
        self.windowID = windowID
        self.source = source
        self.onEvent = onEvent
    }

    public func poll() {
        guard !closed else { return }
        guard let snap = source(windowID).compactMap(WindowSnapshot.init(info:)).first(where: { $0.id == windowID })
        else {
            closed = true
            stop()
            onEvent(.closed)
            return
        }
        guard snap.isOnScreen else {
            if !hidden {
                hidden = true
                last = nil  // force a `.changed` on return, even at the same frame
                onEvent(.hidden)
            }
            return
        }
        hidden = false
        if snap.frame != last {
            last = snap.frame
            stillPolls = 0
            setRate(activeHz)
            onEvent(.changed(snap.frame))
        } else {
            stillPolls += 1
            if currentHz == activeHz, Double(stillPolls) >= settleTime * activeHz { setRate(idleHz) }
        }
    }

    public func start(activeHz: Double = 60, idleHz: Double = 10, settleTime: Double = 0.5) {
        stop()
        self.activeHz = activeHz
        self.idleHz = idleHz
        self.settleTime = settleTime
        started = true
        currentHz = 0
        setRate(activeHz)
        poll()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        started = false
    }

    /// Without `start()` this only records the rate, so tests can drive `poll()` by hand.
    private func setRate(_ hz: Double) {
        guard hz != currentHz else { return }
        currentHz = hz
        guard started else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / hz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }
}
