// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "g-l-a-s-s",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GlassContrast", targets: ["GlassContrast"]),
        .library(name: "GlassOverlay", targets: ["GlassOverlay"]),
        .executable(name: "GlassDemo", targets: ["GlassDemo"]),
        .executable(name: "GlassCaptureSpike", targets: ["GlassCaptureSpike"]),
    ],
    targets: [
        // Pure Swift, Foundation only: no AppKit/SwiftUI, so it stays portable and fast to test.
        .target(name: "GlassContrast"),
        .executableTarget(name: "GlassDemo", dependencies: ["GlassContrast", "GlassOverlay"]),
        // Spike for DESIGN option B (pending sign-off): window tracking, compositing, text layer.
        // macOS frameworks only, but everything here is testable without Screen Recording.
        .target(name: "GlassOverlay", dependencies: ["GlassContrast"]),
        .executableTarget(name: "GlassCaptureSpike", dependencies: ["GlassContrast", "GlassOverlay"]),
        .testTarget(name: "GlassContrastTests", dependencies: ["GlassContrast"]),
        .testTarget(name: "GlassOverlayTests", dependencies: ["GlassOverlay", "GlassContrast"]),
    ],
    swiftLanguageModes: [.v6]
)
