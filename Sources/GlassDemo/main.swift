import AppKit
import GlassContrast
import SwiftUI

struct GlassDemoApp: App {
    init() {
        // A bare SwiftPM executable launches as a background process; promote it to a real app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("g-l-a-s-s demo") {
            DemoWindow()
        }
        .windowResizability(.contentSize)
    }
}

/// `GlassDemo --snapshot out.png` renders a contact sheet of the simulation at several moments,
/// headless, so the adaptive behaviour can be checked without a display session or permissions.
@MainActor func renderSnapshot(to path: String) {
    let times: [Double] = [0.0, 1.6, 3.2, 4.8, 6.4, 8.0]
    let dt = 1.0 / 30
    let model = DemoModel()
    var frames: [NSImage] = []
    for t in times {
        while model.time + dt / 2 < t { model.step(dt: dt) }
        let renderer = ImageRenderer(content: DemoContentView(model: model, useSystemGlass: false))
        renderer.scale = 1
        if let img = renderer.nsImage { frames.append(img) }
    }
    let sheet = VStack(spacing: 4) {
        ForEach(0..<(frames.count + 1) / 2, id: \.self) { row in
            HStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { col in
                    let i = row * 2 + col
                    if i < frames.count {
                        Image(nsImage: frames[i]).overlay(alignment: .topLeading) {
                            Text(String(format: "t = %.1fs", times[i]))
                                .font(.system(size: 13, weight: .bold).monospacedDigit())
                                .padding(6).background(.black.opacity(0.6)).foregroundStyle(.white)
                        }
                    }
                }
            }
        }
    }
    let renderer = ImageRenderer(content: sheet)
    guard let cg = renderer.cgImage else {
        FileHandle.standardError.write(Data("render failed\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        exit(1)
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot") {
    let path = i + 1 < args.count ? args[i + 1] : "glass-demo.png"
    MainActor.assumeIsolated { renderSnapshot(to: path) }
} else {
    GlassDemoApp.main()
}
