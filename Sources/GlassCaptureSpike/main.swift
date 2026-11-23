// Feasibility spike (2026-11-23) for the overlay architecture in docs/DESIGN.md, option B.
// Throwaway: compiles in CI, has not been run against a real window, because it needs
// Screen Recording permission that can't be granted headless. See README "Running the spike".
import AppKit
import ApplicationServices
import CoreImage
import GlassContrast
@preconcurrency import ScreenCaptureKit

func usage() -> Never {
    print(
        """
        GlassCaptureSpike --check            permission status (never prompts)
        GlassCaptureSpike --list             on-screen windows (needs Screen Recording)
        GlassCaptureSpike --window <app>     glass overlay over that app's frontmost window
                          [--alpha 0.55]     opacity of the window copy over the blurred backdrop
        """)
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

func checkPermissions() -> Bool {
    // Both calls only *read* TCC state; CGRequestScreenCaptureAccess / AXIsProcessTrustedWithOptions
    // with the prompt key are the ones that would pop a dialog.
    let screen = CGPreflightScreenCaptureAccess()
    let ax = AXIsProcessTrusted()
    print("Screen Recording: \(screen ? "granted" : "NOT granted")")
    print("Accessibility:    \(ax ? "granted" : "not granted (only needed for AX text frames, not this spike)")")
    return screen
}

func requireScreenRecording() {
    guard checkPermissions() else {
        print(
            """
            Grant Screen Recording to the app running this binary (e.g. Terminal) in
            System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch.
            """)
        exit(1)
    }
}

switch args[1] {
case "--check":
    _ = checkPermissions()
    exit(0)
case "--list":
    requireScreenRecording()
    Task {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        for w in content.windows where w.windowLayer == 0 {
            let app = w.owningApplication?.applicationName ?? "?"
            print("\(w.windowID)\t\(app)\t\(w.title ?? "")\t\(w.frame)")
        }
        exit(0)
    }
    RunLoop.main.run()
case "--window":
    guard args.count >= 3 else { usage() }
    requireScreenRecording()
    let alpha = args.firstIndex(of: "--alpha").flatMap { Double(args[$0 + 1]) } ?? 0.55
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = OverlayController(appName: args[2], alpha: alpha)
    Task { @MainActor in
        do {
            try await controller.start()
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
    app.run()
default:
    usage()
}

/// Wraps capture-queue values for hand-off to the main actor. IOSurface-backed buffers are
/// immutable once delivered by ScreenCaptureKit, so sharing them across threads is safe.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

@MainActor
final class OverlayController {
    let appName: String
    let alpha: Double
    private var window: NSWindow?
    private let backdropLayer = CALayer()
    private let windowLayer = CALayer()
    private var streams: [SCStream] = []
    private var outputs: [FrameOutput] = []
    private var adaptive = AdaptiveTextColor(original: RGB(hex: 0x000000), solver: ContrastSolver(target: .apca(60)))
    private var lastLog = Date.distantPast

    init(appName: String, alpha: Double) {
        self.appName = appName
        self.alpha = alpha
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard
            let target = content.windows.first(where: {
                $0.owningApplication?.applicationName == appName && $0.windowLayer == 0 && $0.isOnScreen
            })
        else {
            print("no on-screen window for \(appName); try --list")
            exit(1)
        }
        guard let display = content.displays.first(where: { $0.frame.intersects(target.frame) }) else {
            print("target window is not on any display")
            exit(1)
        }

        window = makeOverlay(over: target.frame)
        // Re-query once the overlay exists so it can be excluded too: the backdrop must show what is
        // *behind* the target, without the target and without our own overlay (a feedback loop).
        // `sharingType = .none` may already hide it, but that is not guaranteed for ScreenCaptureKit.
        let refreshed = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownWindows = refreshed.windows.filter { $0.owningApplication?.processID == pid }
        let behind = SCContentFilter(display: display, excludingWindows: [target] + ownWindows)

        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let backdropConfig = SCStreamConfiguration()
        backdropConfig.sourceRect = CGRect(
            x: target.frame.minX - display.frame.minX, y: target.frame.minY - display.frame.minY,
            width: target.frame.width, height: target.frame.height)
        // The backdrop is about to be blurred, so half resolution costs nothing visible.
        backdropConfig.width = Int(target.frame.width * scale / 2)
        backdropConfig.height = Int(target.frame.height * scale / 2)
        backdropConfig.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        backdropConfig.pixelFormat = kCVPixelFormatType_32BGRA
        backdropConfig.showsCursor = false
        backdropConfig.queueDepth = 3

        let windowConfig = SCStreamConfiguration()
        windowConfig.width = Int(target.frame.width * scale)
        windowConfig.height = Int(target.frame.height * scale)
        windowConfig.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        windowConfig.pixelFormat = kCVPixelFormatType_32BGRA
        windowConfig.showsCursor = false
        windowConfig.queueDepth = 3

        try await addStream(filter: behind, config: backdropConfig, role: .backdrop)
        try await addStream(
            filter: SCContentFilter(desktopIndependentWindow: target), config: windowConfig, role: .window)
        print("overlay running over \(appName) window \(target.windowID); Ctrl-C to quit")
    }

    private func makeOverlay(over cgFrame: CGRect) -> NSWindow {
        // ScreenCaptureKit frames use a top-left origin; AppKit uses bottom-left of the main screen.
        let mainHeight = NSScreen.screens.first?.frame.height ?? cgFrame.maxY
        let frame = NSRect(
            x: cgFrame.minX, y: mainHeight - cgFrame.maxY, width: cgFrame.width, height: cgFrame.height)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true  // clicks fall through to the real window underneath
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.sharingType = .none

        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: frame.size)
        backdropLayer.frame = root.bounds
        backdropLayer.contentsGravity = .resize
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 24]) {
            backdropLayer.filters = [blur]
        }
        windowLayer.frame = root.bounds
        windowLayer.contentsGravity = .resize
        windowLayer.opacity = Float(alpha)
        root.addSublayer(backdropLayer)
        root.addSublayer(windowLayer)

        let view = NSView(frame: root.bounds)
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        view.layer = root
        w.contentView = view
        w.orderFrontRegardless()
        return w
    }

    private func addStream(filter: SCContentFilter, config: SCStreamConfiguration, role: FrameOutput.Role) async throws
    {
        let output = FrameOutput(role: role) { [weak self] role, surface, sample in
            Task { @MainActor in self?.present(role: role, surface: surface, sample: sample) }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        streams.append(stream)
        outputs.append(output)
    }

    private func present(role: FrameOutput.Role, surface: Unchecked<IOSurface>, sample: BackgroundSample?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch role {
        case .backdrop: backdropLayer.contents = surface.value
        case .window: windowLayer.contents = surface.value
        }
        CATransaction.commit()

        // Spike stand-in for text recolouring: report what colour default black text would need
        // to stay readable over the new backdrop. Real build feeds per-text-region samples.
        if let sample {
            let c = adaptive.update(background: sample, dt: 1.0 / 30)
            if Date().timeIntervalSince(lastLog) > 1 {
                lastLog = Date()
                print(
                    String(
                        format: "backdrop → text colour #%02X%02X%02X (polarity %@)",
                        Int(c.r * 255), Int(c.g * 255), Int(c.b * 255),
                        adaptive.polarity == .lighter ? "light" : "dark"))
            }
        }
    }
}

final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Role: Sendable { case backdrop, window }
    let role: Role
    let queue = DispatchQueue(label: "glass.capture", qos: .userInteractive)
    private let onFrame: @Sendable (Role, Unchecked<IOSurface>, BackgroundSample?) -> Void

    init(role: Role, onFrame: @escaping @Sendable (Role, Unchecked<IOSurface>, BackgroundSample?) -> Void) {
        self.role = role
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
            let pixels = sampleBuffer.imageBuffer,
            let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue()
        else { return }
        let sample = role == .backdrop ? Self.sample(pixels) : nil
        onFrame(role, Unchecked(value: surface), sample)
    }

    /// Coarse 16×16 grid of BGRA pixels: enough for the solver's quantiles, cheap enough for 30 fps.
    static func sample(_ buffer: CVPixelBuffer) -> BackgroundSample {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return BackgroundSample(colors: []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var colors: [RGB] = []
        colors.reserveCapacity(256)
        for gy in 0..<16 {
            for gx in 0..<16 {
                let x = (gx * 2 + 1) * w / 32, y = (gy * 2 + 1) * h / 32
                let p = bytes + y * stride + x * 4
                colors.append(RGB(r: Double(p[2]) / 255, g: Double(p[1]) / 255, b: Double(p[0]) / 255))
            }
        }
        return BackgroundSample(colors: colors)
    }
}
