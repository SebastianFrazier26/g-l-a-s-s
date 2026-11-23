import AppKit
import CoreGraphics

public struct DisplayInfo: Equatable, Sendable {
    public let id: CGDirectDisplayID
    /// Global CG coordinates (top-left origin at the primary display), in points.
    public let frame: CGRect
    public let scale: Double

    public init(id: CGDirectDisplayID, frame: CGRect, scale: Double) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

/// Which display a window belongs to, and how to capture its backdrop there.
///
/// ScreenCaptureKit display filters capture one display, so a window straddling two displays only
/// gets a real backdrop for the part on its majority display; `coverage` says which part that is,
/// and the compositor extends the nearest edge over the rest (blurred, it reads as continuous).
public enum DisplayLayout {
    public static func best(for window: CGRect, among displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (DisplayInfo, CGFloat)?
        for d in displays {
            let i = window.intersection(d.frame)
            guard !i.isNull else { continue }
            let area = i.width * i.height
            if area > 0, area > (best?.1 ?? 0) { best = (d, area) }
        }
        return best?.0
    }

    /// Display-local rect to capture: the window's part on this display.
    public static func sourceRect(window: CGRect, display: DisplayInfo) -> CGRect {
        let i = window.intersection(display.frame)
        guard !i.isNull else { return .zero }
        return i.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    /// The same part, in window-local top-left points.
    public static func coverage(window: CGRect, display: DisplayInfo) -> CGRect {
        let i = window.intersection(display.frame)
        guard !i.isNull else { return .zero }
        return i.offsetBy(dx: -window.minX, dy: -window.minY)
    }

    /// Capture size in pixels on a display of `scale`; never below 2×2 (ScreenCaptureKit rejects 0).
    public static func pixelSize(_ size: CGSize, scale: Double, factor: Double = 1) -> (Int, Int) {
        (max(2, Int((size.width * scale * factor).rounded())), max(2, Int((size.height * scale * factor).rounded())))
    }

    @MainActor public static func systemDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(n.uint32Value)
            return DisplayInfo(id: id, frame: CGDisplayBounds(id), scale: Double(screen.backingScaleFactor))
        }
    }
}

/// Windows drawn in front of the target: menus, popovers, tooltips, sheets, other apps' windows.
/// The overlay cuts holes where they are, so they stay visible and clickable as themselves even
/// if z-ordering the overlay relative to another process's window turns out to be unreliable.
public enum Occlusion {
    /// `list` must be front-to-back (CGWindowList order). Result is in target-local top-left points.
    public static func occluders(of target: CGWindowID, in list: [[String: Any]], ignoringPID: pid_t) -> [CGRect] {
        let snaps = list.compactMap { info -> (WindowSnapshot, Double)? in
            guard let s = WindowSnapshot(info: info) else { return nil }
            return (s, (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
        guard let idx = snaps.firstIndex(where: { $0.0.id == target }) else { return [] }
        let t = snaps[idx].0.frame
        return snaps[..<idx].compactMap { s, alpha in
            guard s.ownerPID != ignoringPID, alpha > 0, s.isOnScreen else { return nil }
            let i = s.frame.intersection(t)
            guard !i.isNull, i.width > 0, i.height > 0 else { return nil }
            return i.offsetBy(dx: -t.minX, dy: -t.minY)
        }
    }

    /// Grid test (32×32 cell centres): cheap, and exact enough to decide whether to pause capture.
    public static func isFullyCovered(_ size: CGSize, by rects: [CGRect]) -> Bool {
        guard !rects.isEmpty, size.width > 0, size.height > 0 else { return false }
        let n = 32
        for gy in 0..<n {
            for gx in 0..<n {
                let p = CGPoint(
                    x: (Double(gx) + 0.5) * size.width / Double(n), y: (Double(gy) + 0.5) * size.height / Double(n))
                if !rects.contains(where: { $0.contains(p) }) { return false }
            }
        }
        // Grid centres can miss slivers at the edges; require the union's bounds to span the window.
        let u = rects.reduce(CGRect.null) { $0.union($1) }
        return u.minX <= 0 && u.minY <= 0 && u.maxX >= size.width && u.maxY >= size.height
    }
}

/// Exponential backoff for restarting a capture stream that stopped with an error.
public struct RestartPolicy: Sendable {
    public let base: Double
    public let cap: Double
    public let maxAttempts: Int
    private var attempts = 0

    public init(base: Double = 0.5, cap: Double = 8, maxAttempts: Int = 6) {
        self.base = base
        self.cap = cap
        self.maxAttempts = maxAttempts
    }

    public mutating func nextDelay() -> Double? {
        guard attempts < maxAttempts else { return nil }
        defer { attempts += 1 }
        return min(cap, base * pow(2, Double(attempts)))
    }

    public mutating func reset() { attempts = 0 }
}
