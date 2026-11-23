// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "g-l-a-s-s",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GlassContrast", targets: ["GlassContrast"])
    ],
    targets: [
        // Pure Swift, Foundation only: no AppKit/SwiftUI, so it stays portable and fast to test.
        .target(name: "GlassContrast"),
        .testTarget(name: "GlassContrastTests", dependencies: ["GlassContrast"]),
    ],
    swiftLanguageModes: [.v6]
)
