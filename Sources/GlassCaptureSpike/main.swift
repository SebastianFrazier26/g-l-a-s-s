// Feasibility spike (2026-11-23) for docs/DESIGN.md option B, which was approved 2026-11-23.
// Not yet run against a real window: capture needs Screen Recording, which can't be granted headless.
// Build the bundled app with scripts/bundle-spike.sh and follow README "Running the spike".
import AppKit
import ApplicationServices
import GlassContrast
import GlassOverlay
@preconcurrency import ScreenCaptureKit

struct Options {
    var command = ""
    var appName = ""
    var mode = OwnerDefaults.transparency
    var alpha = TransparencySetting.defaultUniformAlpha
    var urgent = false
    var hueShift = OwnerDefaults.hueShift
    var text = true
    var fps = 30
    var key: RGB?

    static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        guard let cmd = it.next() else { return nil }
        o.command = cmd
        if cmd == "--window" {
            guard let name = it.next() else { return nil }
            o.appName = name
        }
        while let a = it.next() {
            switch a {
            case "--mode":
                guard let m = it.next().flatMap(TransparencySetting.init(parsing:)) else { return nil }
                o.mode = m
            case "--alpha": o.alpha = it.next().flatMap(Double.init) ?? o.alpha
            case "--fps": o.fps = it.next().flatMap(Int.init) ?? o.fps
            case "--key":
                o.key = it.next().flatMap { UInt32($0.trimmingCharacters(in: ["#"]), radix: 16) }.map(RGB.init(hex:))
            case "--urgent-easing": o.urgent = true
            case "--hue-shift":
                guard let s = it.next().flatMap(HueShiftPolicy.Strategy.init(parsing:)) else { return nil }
                o.hueShift.strategy = s
            case "--no-text": o.text = false
            default: return nil
            }
        }
        return o
    }
}

func usage() -> Never {
    print(
        """
        GlassCaptureSpike --check                 permission status (never prompts)
        GlassCaptureSpike --request-access        ask macOS for Screen Recording (shows the system prompt)
        GlassCaptureSpike --list                  on-screen app windows (no permission needed)
        GlassCaptureSpike --window <App> [options]
            --mode keyed|uniform   keyed (default): window background turns to glass, content stays solid
            --alpha 0.55           window-copy opacity in uniform mode
            --key RRGGBB           key colour for keyed mode (default: the window's dominant colour)
            --urgent-easing        fast easing while text is unreadable (off: owner chose "always smooth")
            --hue-shift complementary|nearest|lightness
                                   how text colour may move (default complementary: hue toward the backdrop complement)
            --no-text              skip OCR and text recolouring
            --fps 30
        """)
    exit(2)
}

/// Inside the .app (launched via `open`, so TCC attributes permission to the app rather than the
/// terminal) stdout goes nowhere; mirror it to a log file instead.
func redirectOutputIfDetached() {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return }
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/g-l-a-s-s")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("spike.log").path
    freopen(path, "a", stdout)
    freopen(path, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
    print("--- \(Date()) \(CommandLine.arguments.dropFirst().joined(separator: " "))")
}

func checkPermissions() -> Bool {
    // Preflight calls only read TCC state; they never show a prompt.
    let screen = CGPreflightScreenCaptureAccess()
    print("Screen Recording: \(screen ? "granted" : "NOT granted")")
    print("Accessibility:    \(AXIsProcessTrusted() ? "granted" : "not granted (not needed by this spike)")")
    print("Executable:       \(Bundle.main.bundlePath)")
    return screen
}

redirectOutputIfDetached()
guard let opts = Options.parse(CommandLine.arguments) else { usage() }

switch opts.command {
case "--check":
    _ = checkPermissions()
    exit(0)
case "--request-access":
    // The one place a prompt is allowed: the user explicitly asked for it.
    print(CGRequestScreenCaptureAccess() ? "granted" : "not granted yet: enable it in System Settings, then relaunch")
    exit(0)
case "--list":
    for w in WindowList.allOnScreen().compactMap(WindowSnapshot.init(info:)) where w.layer == 0 {
        print("\(w.id)\t\(w.ownerName)\t\(w.frame)")
    }
    exit(0)
case "--window":
    guard checkPermissions() else {
        print("Screen Recording is required. Run with --request-access, enable it, relaunch.")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MainActor.assumeIsolated { OverlayController(options: opts) }
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

@MainActor
final class OverlayController {
    let options: Options
    let pipeline: OverlayPipeline
    private var overlay: OverlayWindow?
    private var tracker: WindowTracker?
    private var backdropStream: SCStream?
    private var windowStream: SCStream?
    private var outputs: [FrameOutput] = []
    private var target: SCWindow?
    private var display: SCDisplay?
    private var displayInfo: DisplayInfo?
    private var excluded: [SCWindow] = []
    private var lastSize: CGSize = .zero
    private var currentFrame: CGRect = .zero
    private var hidden = false
    private var occlusionTimer: Timer?
    private var restart = RestartPolicy()
    private lazy var streamDelegate = StreamDelegate { [weak self] error in
        Task { @MainActor in await self?.streamStopped(error) }
    }
    private var frames = 0
    private var lastReport = Date()

    init(options: Options) {
        self.options = options
        var o = OverlayPipeline.Options(transparency: options.mode, uniformAlpha: options.alpha, key: options.key)
        o.urgentOmega = options.urgent ? 40 : OwnerDefaults.urgentOmega
        o.textEnabled = options.text
        o.hueShift = options.hueShift
        pipeline = OverlayPipeline(options: o)
    }

    func start() async throws {
        guard let snap = WindowList.frontmostWindow(ownedBy: options.appName, in: WindowList.allOnScreen()) else {
            print("no on-screen window for \(options.appName); try --list")
            exit(1)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let info = DisplayLayout.best(for: snap.frame, among: DisplayLayout.systemDisplays())
        guard let target = content.windows.first(where: { $0.windowID == snap.id }),
            let info, let display = content.displays.first(where: { $0.displayID == info.id })
        else {
            print("ScreenCaptureKit can't see window \(snap.id) on any display")
            exit(1)
        }
        displayInfo = info
        pipeline.setDisplayGamut(info.gamut)
        self.target = target
        self.display = display

        let overlay = OverlayWindow(cgFrame: snap.frame)
        overlay.orderFrontRegardless()
        overlay.follow(cgFrame: snap.frame, targetWindowNumber: Int(snap.id))
        self.overlay = overlay

        // Re-query so our own overlay can be excluded from the backdrop (else: feedback loop).
        let refreshed = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        excluded = [target] + refreshed.windows.filter { $0.owningApplication?.processID == pid }

        let backdrop = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: excluded),
            configuration: backdropConfig(for: snap.frame), delegate: streamDelegate)
        let window = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: target),
            configuration: windowConfig(for: snap.frame.size), delegate: streamDelegate)
        try addOutput(to: backdrop, role: .backdrop)
        try addOutput(to: window, role: .window)
        try await backdrop.startCapture()
        try await window.startCapture()
        backdropStream = backdrop
        windowStream = window
        lastSize = snap.frame.size
        currentFrame = snap.frame
        updateGeometry()
        pipeline.startAnalysis()
        occlusionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGeometry() }
        }

        let tracker = WindowTracker(windowID: snap.id) { [weak self] event in self?.handle(event) }
        tracker.start(hz: 60)
        self.tracker = tracker
        print("glassing \(options.appName) window \(snap.id) (\(options.mode)); quit with: pkill -x GlassCaptureSpike")
    }

    private func handle(_ event: WindowTracker.Event) {
        switch event {
        case .closed:
            print("target window closed")
            exit(0)
        case .hidden:
            hidden = true
            pipeline.setPaused(true)
            overlay?.orderOut(nil)
        case .changed(let frame):
            hidden = false
            currentFrame = frame
            overlay?.follow(cgFrame: frame, targetWindowNumber: Int(tracker?.windowID ?? 0))
            let sizeChanged = frame.size != lastSize
            lastSize = frame.size
            let newInfo = DisplayLayout.best(for: frame, among: DisplayLayout.systemDisplays())
            let displayChanged = newInfo != nil && newInfo?.id != displayInfo?.id
            if let newInfo {
                if newInfo.gamut != displayInfo?.gamut { pipeline.setDisplayGamut(newInfo.gamut) }
                displayInfo = newInfo
            }
            updateGeometry()
            Task {
                if displayChanged { await switchBackdropDisplay() }
                try? await backdropStream?.updateConfiguration(backdropConfig(for: frame))
                if sizeChanged || displayChanged {
                    try? await windowStream?.updateConfiguration(windowConfig(for: frame.size))
                }
            }
        }
    }

    /// Holes for windows in front of the target, backdrop coverage when straddling displays, and
    /// pausing while fully covered. Polled at 10 Hz: menus and popovers open at human speed.
    private func updateGeometry() {
        guard !hidden, let tracker, let displayInfo else { return }
        let s = scale
        let px = { (r: CGRect) in CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s) }
        let occluders = Occlusion.occluders(
            of: tracker.windowID, in: WindowList.allOnScreen(), ignoringPID: ProcessInfo.processInfo.processIdentifier)
        let coverage = DisplayLayout.coverage(window: currentFrame, display: displayInfo)
        let full = CGRect(origin: .zero, size: currentFrame.size)
        pipeline.setGeometry(holes: occluders.map(px), backdropCoverage: coverage == full ? nil : px(coverage))
        pipeline.setPaused(Occlusion.isFullyCovered(currentFrame.size, by: occluders))
    }

    private func switchBackdropDisplay() async {
        guard let displayInfo,
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let display = content.displays.first(where: { $0.displayID == displayInfo.id })
        else { return }
        self.display = display
        try? await backdropStream?.updateContentFilter(SCContentFilter(display: display, excludingWindows: excluded))
        print("target moved to display \(displayInfo.id) (scale \(displayInfo.scale), \(displayInfo.gamut))")
    }

    private func streamStopped(_ error: Error) async {
        print("capture stopped: \(error.localizedDescription)")
        guard CGPreflightScreenCaptureAccess() else {
            print("Screen Recording was revoked; exiting. Re-enable it and relaunch.")
            exit(3)
        }
        guard let delay = restart.nextDelay() else {
            print("capture keeps failing; giving up")
            exit(4)
        }
        try? await Task.sleep(for: .seconds(delay))
        do {
            try await backdropStream?.startCapture()
            try await windowStream?.startCapture()
            restart.reset()
            print("capture restarted")
        } catch {
            await streamStopped(error)
        }
    }

    /// Pixels per point of the display the target is on (not the main screen's).
    private var scale: Double { displayInfo?.scale ?? 2 }

    private func backdropConfig(for frame: CGRect) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        guard let displayInfo else { return c }
        let source = DisplayLayout.sourceRect(window: frame, display: displayInfo)
        c.sourceRect = source
        // Blurred anyway, so half resolution costs nothing visible.
        (c.width, c.height) = DisplayLayout.pixelSize(source.size, scale: displayInfo.scale, factor: 0.5)
        common(c)
        return c
    }

    private func windowConfig(for size: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        (c.width, c.height) = DisplayLayout.pixelSize(size, scale: scale)
        common(c)
        return c
    }

    private func common(_ c: SCStreamConfiguration) {
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
    }

    private func addOutput(to stream: SCStream, role: FrameOutput.Role) throws {
        let pipeline = self.pipeline
        let output = FrameOutput(role: role) { [weak self] role, buffer in
            switch role {
            case .backdrop:
                pipeline.ingestBackdrop(buffer.value)
            case .window:
                guard let out = pipeline.ingestWindow(buffer.value),
                    let surface = CVPixelBufferGetIOSurface(out)?.takeUnretainedValue()
                else { return }
                let box = Unchecked(value: surface)
                Task { @MainActor in self?.present(box.value) }
            }
        }
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        outputs.append(output)
    }

    private func present(_ surface: IOSurface) {
        overlay?.contentLayer.contents = surface
        frames += 1
        if Date().timeIntervalSince(lastReport) >= 5 {
            print(String(format: "%.1f fps composited", Double(frames) / Date().timeIntervalSince(lastReport)))
            frames = 0
            lastReport = Date()
        }
    }
}

/// Hands capture-queue values to other threads. ScreenCaptureKit buffers are IOSurface-backed and
/// not written after delivery, so sharing them is safe.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (Error) -> Void

    init(onStop: @escaping @Sendable (Error) -> Void) { self.onStop = onStop }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(error) }
}

final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Role: Sendable { case backdrop, window }
    let role: Role
    let queue = DispatchQueue(label: "glass.capture", qos: .userInteractive)
    private let onFrame: @Sendable (Role, Unchecked<CVPixelBuffer>) -> Void

    init(role: Role, onFrame: @escaping @Sendable (Role, Unchecked<CVPixelBuffer>) -> Void) {
        self.role = role
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer else { return }
        onFrame(role, Unchecked(value: pixels))
    }
}
