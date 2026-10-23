// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExteraProxySearch",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ExteraProxySearch", targets: ["ExteraProxySearch"])],
    targets: [
        .target(name: "ExteraProxySearch"),
        .testTarget(name: "ExteraProxySearchTests", dependencies: ["ExteraProxySearch"])
    ]
)
