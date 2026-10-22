// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExteraTranslation",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ExteraTranslation", targets: ["ExteraTranslation"])],
    targets: [
        .target(name: "ExteraTranslation"),
        .testTarget(name: "ExteraTranslationTests", dependencies: ["ExteraTranslation"])
    ]
)
