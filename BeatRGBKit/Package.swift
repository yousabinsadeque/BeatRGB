// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeatRGBKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BeatRGBKit", targets: ["BeatRGBKit"]),
    ],
    targets: [
        .target(name: "BeatRGBKit", resources: [.copy("Resources/k70-core-tkl.bin")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BeatRGBKitTests", dependencies: ["BeatRGBKit"], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
