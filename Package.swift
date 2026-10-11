// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ToneCore",
    products: [.library(name: "ToneCore", targets: ["ToneCore"])],
    targets: [
        .target(name: "ToneCore", path: "Tone/Core"),
        .testTarget(name: "ToneCoreTests", dependencies: ["ToneCore"], path: "Tests/ToneCoreTests")
    ]
)
