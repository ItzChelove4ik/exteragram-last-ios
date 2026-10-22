// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExteraPreferences",
    platforms: [.iOS(.v15)],
    products: [.library(name: "ExteraPreferences", targets: ["ExteraPreferences"])],
    targets: [
        .target(name: "ExteraPreferences"),
        .testTarget(name: "ExteraPreferencesTests", dependencies: ["ExteraPreferences"])
    ]
)
