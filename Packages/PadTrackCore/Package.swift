// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PadTrackCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PadTrackCore", targets: ["PadTrackCore"]),
        // Mac only in practice: the HTTP + WebSocket server for the Safari client.
        .library(name: "PadTrackWeb", targets: ["PadTrackWeb"]),
    ],
    targets: [
        .target(name: "PadTrackCore"),
        .target(name: "PadTrackWeb", dependencies: ["PadTrackCore"]),
        .testTarget(name: "PadTrackCoreTests", dependencies: ["PadTrackCore"]),
        .testTarget(name: "PadTrackWebTests", dependencies: ["PadTrackWeb", "PadTrackCore"]),
    ]
)
