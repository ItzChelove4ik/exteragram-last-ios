// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExteraResources",
    defaultLocalization: "en",
    platforms: [.iOS(.v15)],
    products: [.library(name: "ExteraResources", targets: ["ExteraResources"])],
    targets: [
        .target(name: "ExteraResources", resources: [.process("Resources")]),
        .testTarget(name: "ExteraResourcesTests", dependencies: ["ExteraResources"])
    ]
)
