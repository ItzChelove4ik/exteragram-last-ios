// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExteraSpeech",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ExteraSpeech", targets: ["ExteraSpeech"])],
    targets: [
        .target(name: "ExteraSpeech", linkerSettings: [
            .linkedFramework("Speech", .when(platforms: [.iOS])),
            .linkedFramework("AVFoundation", .when(platforms: [.iOS]))
        ]),
        .testTarget(name: "ExteraSpeechTests", dependencies: ["ExteraSpeech"])
    ]
)
