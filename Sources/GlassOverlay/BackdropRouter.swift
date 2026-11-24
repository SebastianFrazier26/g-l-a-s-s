import CoreGraphics
import CoreImage
import Foundation

/// Splits one display capture into per-window backdrops (owner decision 2026-11-23: one process for
/// all glassed windows, sharing one backdrop capture per display instead of one per window).
///
/// Trade-off accepted with that decision: the shared capture has to exclude *every* glassed window,
/// so one glassed window's glass shows what is behind the whole group, not another glassed window
/// that sits behind it.
public final class BackdropRouter: @unchecked Sendable {
    public struct Route: Equatable, Sendable {
        public var display: CGDirectDisplayID
        /// The window's part on that display, in display-local top-left points
        /// (`DisplayLayout.sourceRect`).
        public var sourceRect: CGRect
        /// The display's size in points.
        public var displaySize: CGSize

        public init(display: CGDirectDisplayID, sourceRect: CGRect, displaySize: CGSize) {
            self.display = display
            self.sourceRect = sourceRect
            self.displaySize = displaySize
        }
    }

    public typealias Sink = @Sendable (CIImage) -> Void

    private let lock = NSLock()
    private var routes: [CGWindowID: (route: Route, sink: Sink)] = [:]
    /// Per window, backdrop frames skipped because nothing changed under it.
    private var skipped: [CGWindowID: Int] = [:]
    private var fed: Set<CGWindowID> = []

    public init() {}

    public func set(_ id: CGWindowID, route: Route, sink: @escaping Sink) {
        lock.withLock { routes[id] = (route, sink) }
    }

    public func update(_ id: CGWindowID, route: Route) {
        lock.withLock { routes[id]?.route = route }
    }

    public func remove(_ id: CGWindowID) {
        lock.withLock {
            routes[id] = nil
            skipped[id] = nil
            fed.remove(id)
        }
    }

    public var displaysInUse: Set<CGDirectDisplayID> { lock.withLock { Set(routes.values.map(\.route.display)) } }

    public func takeSkipped(_ id: CGWindowID) -> Int {
        lock.withLock {
            defer { skipped[id] = 0 }
            return skipped[id] ?? 0
        }
    }

    /// Hands each window on `display` its crop of `frame`. `dirtyRects` are in the frame's top-left
    /// pixels, as ScreenCaptureKit reports them; a window none of them touches is skipped, since its
    /// backdrop did not change. nil or empty means "unknown": everyone gets the frame. A window that
    /// has never had a backdrop always gets one, or a static window would never be drawn.
    public func deliver(_ frame: CIImage, display: CGDirectDisplayID, dirtyRects: [CGRect]?) {
        let targets = lock.withLock {
            routes.filter { $0.value.route.display == display }.compactMap { id, entry -> (Sink, Route)? in
                let px = Self.framePixels(entry.route, frameSize: frame.extent.size)
                if let dirtyRects, !dirtyRects.isEmpty, fed.contains(id),
                    !dirtyRects.contains(where: { $0.intersects(px) })
                {
                    skipped[id, default: 0] += 1
                    return nil
                }
                fed.insert(id)
                return (entry.sink, entry.route)
            }
        }
        // Outside the lock: sinks composite, which takes tens of milliseconds.
        for (sink, route) in targets { sink(Self.crop(frame, route: route)) }
    }

    /// The route's rect in the frame's top-left pixel space.
    static func framePixels(_ r: Route, frameSize: CGSize) -> CGRect {
        guard r.displaySize.width > 0, r.displaySize.height > 0 else { return .null }
        let sx = frameSize.width / r.displaySize.width, sy = frameSize.height / r.displaySize.height
        return CGRect(
            x: r.sourceRect.minX * sx, y: r.sourceRect.minY * sy, width: r.sourceRect.width * sx,
            height: r.sourceRect.height * sy)
    }

    /// The window's part of a display frame, moved to the origin. Core Image is bottom-left, the
    /// route top-left.
    public static func crop(_ frame: CIImage, route: Route) -> CIImage {
        let e = frame.extent
        let px = framePixels(route, frameSize: e.size)
        let ci = CGRect(x: e.minX + px.minX, y: e.maxY - px.maxY, width: px.width, height: px.height)
        return frame.cropped(to: ci).transformed(by: CGAffineTransform(translationX: -ci.minX, y: -ci.minY))
    }
}
