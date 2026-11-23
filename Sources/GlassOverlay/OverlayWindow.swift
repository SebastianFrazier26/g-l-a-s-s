import AppKit
import QuartzCore

/// Borderless, transparent, click-through window that sits directly above one target window.
@MainActor
public final class OverlayWindow: NSWindow {
    public let contentLayer = CALayer()

    public init(cgFrame: CGRect) {
        super.init(
            contentRect: ScreenGeometry.appKitFrame(fromCG: cgFrame, primaryHeight: ScreenGeometry.primaryHeight),
            styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true  // every click, scroll and drag reaches the real window below
        isReleasedWhenClosed = false
        // Normal level, ordered relative to the target, rather than `.floating`: a floating overlay
        // would stay on top when another app's window is brought over the target.
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = contentLayer
        contentLayer.contentsGravity = .resize
        contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        contentView = view
    }

    /// Follows a target frame reported by `WindowTracker` (CG, top-left coordinates).
    public func follow(cgFrame: CGRect, targetWindowNumber: Int) {
        setFrame(
            ScreenGeometry.appKitFrame(fromCG: cgFrame, primaryHeight: ScreenGeometry.primaryHeight), display: false)
        // Unverified across apps on macOS 26: ordering relative to another process's window number.
        // If it misbehaves, the fallback is `.floating` plus hiding while the target app is inactive.
        order(.above, relativeTo: targetWindowNumber)
    }
}
