// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PadTrackCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PadTrackCore", targets: ["PadTrackCore"]),
    ],
    targets: [
        .target(name: "PadTrackCore"),
        .testTarget(name: "PadTrackCoreTests", dependencies: ["PadTrackCore"]),
    ]
)
