// Feasibility spike (2026-11-23) for docs/DESIGN.md option B, which was approved 2026-11-23.
// First live run 2026-11-23 (dark mode, 3 instances): see docs/perf.md for what failed and why.
// Since then one process glasses every named window and shares one backdrop capture per display.
// Build the bundled app with scripts/bundle-spike.sh and follow README "Running the spike".
import AppKit
import ApplicationServices
import GlassContrast
import GlassOverlay
@preconcurrency import ScreenCaptureKit

struct Options {
    var command = ""
    var appNames: [String] = []
    /// Debug escape hatch: ignore ScreenCaptureKit's dirty rects and hand every backdrop frame to
    /// every window, in case their coordinate space turns out not to be frame pixels.
    var useDirtyRects = true
    var mode = OwnerDefaults.transparency
    var look = OwnerDefaults.look
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
            o.appNames = [name]
        }
        while let a = it.next() {
            switch a {
            case "--window" where cmd == "--window":
                guard let name = it.next() else { return nil }
                o.appNames.append(name)
            case "--all-backdrop-frames": o.useDirtyRects = false
            case "--mode":
                guard let m = it.next().flatMap(TransparencySetting.init(parsing:)) else { return nil }
                o.mode = m
            case "--transparency":
                guard let v = GlassLook.parse(it.next(), in: GlassLook.transparencyRange) else { return nil }
                o.look.transparency = v
            case "--alpha":
                guard let v = GlassLook.parse(it.next(), in: 0...1) else { return nil }
                o.look.transparency = 1 - v
            case "--tint":
                guard let v = GlassLook.parse(it.next(), in: GlassLook.tintRange) else { return nil }
                o.look.tintOpacity = v
            case "--blur":
                guard let v = GlassLook.parse(it.next(), in: GlassLook.blurRange) else { return nil }
                o.look.blurRadius = v
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
        GlassCaptureSpike --window <App> [--window <App> ...] [options]
                                   one process glasses the frontmost window of each app
            --mode keyed|uniform   keyed (default): window background turns to glass, content stays solid
            --transparency 0...1   share of the window's own content replaced by glass
                                   (default: keyed 0.2, uniform 0.7)
            --alpha 0...1          window-copy opacity; same as --transparency 1-alpha
            --tint 0...0.5         white frosting over the backdrop (default 0.04)
            --blur 0...40          backdrop blur sigma in pixels, 2 px = 1 pt on Retina (default 6)
            --key RRGGBB           key colour for keyed mode (default: the window's dominant colour)
            --urgent-easing        fast easing while text is unreadable (off: owner chose "always smooth")
            --hue-shift complementary|nearest|lightness
                                   how text colour may move (default complementary: hue toward the backdrop complement)
            --no-text              skip OCR and text recolouring
            --fps 30
            --all-backdrop-frames  debug: don't skip windows outside a backdrop frame's dirty rects
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
    let session = MainActor.assumeIsolated { GlassSession(options: opts) }
    Task { @MainActor in
        do {
            try await session.start()
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
final class GlassSession {
    let options: Options
    private let router = BackdropRouter()
    private var windows: [CGWindowID: GlassedWindow] = [:]
    private var displayStreams: [CGDirectDisplayID: SCStream] = [:]
    private var outputs: [FrameOutput] = []
    private var excluded: [SCWindow] = []
    private var timer: Timer?
    private var restart = RestartPolicy()
    private var lastReport = Date()
    private lazy var streamDelegate = StreamDelegate { [weak self] stream, error in
        Task { @MainActor in await self?.streamStopped(stream.value, error) }
    }

    init(options: Options) { self.options = options }

    func start() async throws {
        let list = WindowList.allOnScreen()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = DisplayLayout.systemDisplays()
        for app in options.appNames {
            guard let snap = WindowList.frontmostWindow(ownedBy: app, in: list) else {
                print("no on-screen window for \(app); skipping (try --list)")
                continue
            }
            guard windows[snap.id] == nil, let target = content.windows.first(where: { $0.windowID == snap.id }),
                let info = DisplayLayout.best(for: snap.frame, among: displays)
            else {
                print("ScreenCaptureKit can't see \(app) window \(snap.id) on any display; skipping")
                continue
            }
            windows[snap.id] = GlassedWindow(
                appName: app, target: target, frame: snap.frame, display: info, options: options)
        }
        guard !windows.isEmpty else {
            print("nothing to glass")
            exit(1)
        }

        // Re-query so our own overlays exist and can be excluded (else: feedback loop). Every target
        // is excluded too: the shared capture must show what is *behind* them.
        let refreshed = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        excluded = windows.values.map(\.target) + refreshed.windows.filter { $0.owningApplication?.processID == pid }

        for w in windows.values {
            router.set(w.id, route: w.route, sink: w.backdropSink)
            try await w.startCapture(delegate: streamDelegate, fps: options.fps)
        }
        try await syncDisplayStreams(content: refreshed)
        updateGeometry()
        for w in windows.values {
            w.startTracking { [weak self] id, event in self?.handle(id, event) }
            print("glassing \(w.appName) window \(w.id) (\(options.mode))")
        }
        print(
            "\(windows.count) window(s), \(displayStreams.count) backdrop capture(s); quit with: pkill -x GlassCaptureSpike"
        )
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGeometry() }
        }
    }

    /// One backdrop stream per display that has a glassed window on it; none for the others.
    private func syncDisplayStreams(content known: SCShareableContent? = nil) async throws {
        let wanted = router.displaysInUse
        for (id, stream) in displayStreams where !wanted.contains(id) {
            try? await stream.stopCapture()
            displayStreams[id] = nil
        }
        let missing = wanted.subtracting(displayStreams.keys)
        guard !missing.isEmpty else { return }
        let content: SCShareableContent
        if let given = known {
            content = given
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        let infos = DisplayLayout.systemDisplays()
        for id in missing {
            guard let display = content.displays.first(where: { $0.displayID == id }),
                let info = infos.first(where: { $0.id == id })
            else { continue }
            let c = SCStreamConfiguration()
            // Blurred anyway, so half resolution costs nothing visible.
            (c.width, c.height) = DisplayLayout.pixelSize(info.frame.size, scale: info.scale, factor: 0.5)
            commonConfig(c, fps: options.fps)
            let stream = SCStream(
                filter: SCContentFilter(display: display, excludingWindows: excluded), configuration: c,
                delegate: streamDelegate)
            let router = self.router
            let useDirty = options.useDirtyRects
            let output = FrameOutput { buffer, dirty in
                router.deliver(CIImage(cvPixelBuffer: buffer.value), display: id, dirtyRects: useDirty ? dirty : nil)
            }
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            outputs.append(output)
            try await stream.startCapture()
            displayStreams[id] = stream
            print("backdrop capture on display \(id) (scale \(info.scale), \(info.gamut))")
        }
    }

    private func handle(_ id: CGWindowID, _ event: WindowTracker.Event) {
        guard let w = windows[id] else { return }
        switch event {
        case .closed:
            print("\(w.appName) window closed")
            w.stop()
            router.remove(id)
            windows[id] = nil
            if windows.isEmpty { exit(0) }
            Task { try? await syncDisplayStreams() }
        case .hidden:
            w.hide()
        case .changed(let frame):
            let moved = w.moved(to: frame, displays: DisplayLayout.systemDisplays())
            router.update(id, route: w.route)
            updateGeometry()
            if moved { Task { try? await syncDisplayStreams() } }
        }
    }

    /// One window-list query per tick for every window: holes, z-order, pause, and the stats line.
    private func updateGeometry() {
        let list = WindowList.allOnScreen()
        for w in windows.values { w.updateGeometry(list: list) }
        let dt = Date().timeIntervalSince(lastReport)
        guard dt >= 5 else { return }
        for w in windows.values { print(w.report(over: dt, skipped: router.takeSkipped(w.id))) }
        lastReport = Date()
    }

    private func streamStopped(_ stream: SCStream, _ error: Error) async {
        print("capture stopped: \(error.localizedDescription)")
        // A window stream stops when its window closes, possibly before the tracker notices;
        // restarting it would fail until the shared backoff gives up and exits for every window.
        if let w = windows.values.first(where: { $0.owns(stream) }),
            !WindowList.system(w.id).contains(where: { WindowSnapshot(info: $0)?.id == w.id })
        {
            handle(w.id, .closed)
            return
        }
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
            try await stream.startCapture()
            restart.reset()
            print("capture restarted")
        } catch {
            await streamStopped(stream, error)
        }
    }
}

/// One glassed window: its overlay, pipeline, tracker and window capture. The backdrop comes from
/// the session's shared display capture, through `backdropSink`.
@MainActor
final class GlassedWindow {
    let appName: String
    let target: SCWindow
    let id: CGWindowID
    let pipeline: OverlayPipeline
    private let overlay: OverlayWindow
    private var tracker: WindowTracker?
    private var stream: SCStream?
    private var output: FrameOutput?
    private var display: DisplayInfo
    private var frame: CGRect
    private var hidden = false
    private var presented = 0
    private var reorders = 0
    private let renderQueue = DispatchQueue(label: "glass.recomposite", qos: .userInteractive)
    private let fps: Int

    init(appName: String, target: SCWindow, frame: CGRect, display: DisplayInfo, options: Options) {
        self.appName = appName
        self.target = target
        id = target.windowID
        self.frame = frame
        self.display = display
        fps = options.fps
        var o = OverlayPipeline.Options(transparency: options.mode, look: options.look, key: options.key)
        o.urgentOmega = options.urgent ? 40 : OwnerDefaults.urgentOmega
        o.textEnabled = options.text
        o.hueShift = options.hueShift
        pipeline = OverlayPipeline(options: o)
        pipeline.setDisplayGamut(display.gamut)
        overlay = OverlayWindow(cgFrame: frame)
        overlay.orderFrontRegardless()
        overlay.follow(cgFrame: frame, targetWindowNumber: Int(id))
    }

    var route: BackdropRouter.Route {
        .init(
            display: display.id, sourceRect: DisplayLayout.sourceRect(window: frame, display: display),
            displaySize: display.frame.size)
    }

    var backdropSink: BackdropRouter.Sink {
        let pipeline = self.pipeline
        return { [weak self] image in
            guard let out = pipeline.ingestBackdrop(image: image) else { return }
            Self.present(out, to: self)
        }
    }

    func startCapture(delegate: StreamDelegate, fps: Int) async throws {
        let s = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: target), configuration: windowConfig(), delegate: delegate
        )
        let pipeline = self.pipeline
        let output = FrameOutput { [weak self] buffer, _ in
            guard let out = pipeline.ingestWindow(buffer.value) else { return }
            Self.present(out, to: self)
        }
        try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await s.startCapture()
        stream = s
        self.output = output
        pipeline.startAnalysis { [weak self] in
            Task { @MainActor in self?.recomposite() }
        }
    }

    func startTracking(_ onEvent: @escaping (CGWindowID, WindowTracker.Event) -> Void) {
        let id = self.id
        let t = WindowTracker(windowID: id) { onEvent(id, $0) }
        t.start()
        tracker = t
    }

    func owns(_ s: SCStream) -> Bool { stream === s }

    func stop() {
        tracker?.stop()
        pipeline.stop()
        overlay.orderOut(nil)
        let s = stream
        Task { try? await s?.stopCapture() }
    }

    func hide() {
        hidden = true
        pipeline.setPaused(true)
        overlay.orderOut(nil)
    }

    /// Returns whether the window moved to another display.
    func moved(to newFrame: CGRect, displays: [DisplayInfo]) -> Bool {
        hidden = false
        let sizeChanged = newFrame.size != frame.size
        frame = newFrame
        overlay.follow(cgFrame: newFrame, targetWindowNumber: Int(id))
        var displayChanged = false
        if let info = DisplayLayout.best(for: newFrame, among: displays) {
            displayChanged = info.id != display.id
            if info.gamut != display.gamut { pipeline.setDisplayGamut(info.gamut) }
            display = info
        }
        if sizeChanged || displayChanged {
            let c = windowConfig()
            Task { try? await stream?.updateConfiguration(c) }
        }
        return displayChanged
    }

    /// Holes for windows in front of the target, backdrop coverage when straddling displays,
    /// pausing while fully covered, and putting the overlay back in front of its target.
    func updateGeometry(list: [[String: Any]]) {
        guard !hidden else { return }
        if !Occlusion.isInFront(overlay: CGWindowID(overlay.windowNumber), of: id, in: list) {
            overlay.order(.above, relativeTo: Int(id))
            reorders += 1
        }
        let s = display.scale
        let px = { (r: CGRect) in CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s) }
        let occluders = Occlusion.occluders(of: id, in: list, ignoringPID: ProcessInfo.processInfo.processIdentifier)
        let coverage = DisplayLayout.coverage(window: frame, display: display)
        let full = CGRect(origin: .zero, size: frame.size)
        let moved = pipeline.setGeometry(
            holes: occluders.map(px), backdropCoverage: coverage == full ? nil : px(coverage))
        let toggled = pipeline.setPaused(Occlusion.isFullyCovered(frame.size, by: occluders))
        if moved || toggled { recomposite() }
    }

    /// Rates per second. Window and backdrop frames arrive only when their pixels change, so low
    /// numbers on a static screen are expected; analysis near 0 means it is idling.
    func report(over dt: Double, skipped: Int) -> String {
        let st = pipeline.takeStats()
        func r(_ n: Int) -> String { String(format: "%.1f", Double(n) / dt) }
        defer {
            presented = 0
            reorders = 0
        }
        return "\(appName) per s: window \(r(st.windowFrames)), backdrop \(r(st.backdropFrames)) "
            + "(\(r(skipped)) skipped, unchanged), composited \(r(st.composites)), presented \(r(presented)), "
            + "analysis \(r(st.analyses)), ocr \(r(st.ocrRuns)); z-reorders \(reorders), tracker \(Int(tracker?.currentHz ?? 0)) Hz"
    }

    /// For inputs that arrive outside the capture callbacks (styles, holes): render off the main
    /// thread, present on it.
    private func recomposite() {
        let pipeline = self.pipeline
        renderQueue.async { [weak self] in
            guard let out = pipeline.composite() else { return }
            Self.present(out, to: self)
        }
    }

    nonisolated private static func present(_ out: CVPixelBuffer, to window: GlassedWindow?) {
        guard let surface = CVPixelBufferGetIOSurface(out)?.takeUnretainedValue() else { return }
        let box = Unchecked(value: surface)
        let ref = WeakBox(window)
        Task { @MainActor in
            guard let w = ref.value else { return }
            w.overlay.contentLayer.contents = box.value
            w.presented += 1
        }
    }

    private func windowConfig() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        (c.width, c.height) = DisplayLayout.pixelSize(frame.size, scale: display.scale)
        // Single-window capture includes the drop shadow by default, and the shadowed image is then
        // scaled down into this size, so the copy came out smaller than, and offset from, the window.
        c.ignoreShadowsSingleWindow = true
        commonConfig(c, fps: fps)
        return c
    }
}

func commonConfig(_ c: SCStreamConfiguration, fps: Int) {
    c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    c.pixelFormat = kCVPixelFormatType_32BGRA
    c.showsCursor = false
    c.queueDepth = 3
}

/// Hands capture-queue values to other threads. ScreenCaptureKit buffers are IOSurface-backed and
/// not written after delivery, so sharing them is safe.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

struct WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}

final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (Unchecked<SCStream>, Error) -> Void

    init(onStop: @escaping @Sendable (Unchecked<SCStream>, Error) -> Void) { self.onStop = onStop }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(Unchecked(value: stream), error) }
}

final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "glass.capture", qos: .userInteractive)
    private let onFrame: @Sendable (Unchecked<CVPixelBuffer>, [CGRect]?) -> Void

    init(onFrame: @escaping @Sendable (Unchecked<CVPixelBuffer>, [CGRect]?) -> Void) {
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer else { return }
        let info =
            (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?
            .first
        // Only `.complete` frames carry new pixels; idle/blank/suspended ones repeat or carry nothing.
        if let raw = info?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        let dirty = (info?[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0) }
        onFrame(Unchecked(value: pixels), dirty)
    }
}
