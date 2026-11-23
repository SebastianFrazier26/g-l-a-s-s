// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "g-l-a-s-s",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GlassContrast", targets: ["GlassContrast"]),
        .executable(name: "GlassDemo", targets: ["GlassDemo"]),
        .executable(name: "GlassCaptureSpike", targets: ["GlassCaptureSpike"]),
    ],
    targets: [
        // Pure Swift, Foundation only: no AppKit/SwiftUI, so it stays portable and fast to test.
        .target(name: "GlassContrast"),
        .executableTarget(name: "GlassDemo", dependencies: ["GlassContrast"]),
        .executableTarget(name: "GlassCaptureSpike", dependencies: ["GlassContrast"]),
        .testTarget(name: "GlassContrastTests", dependencies: ["GlassContrast"]),
    ],
    swiftLanguageModes: [.v6]
)
