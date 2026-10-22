// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExteraExport",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ExteraExport", targets: ["ExteraExport"])],
    targets: [.target(name: "ExteraExport"), .testTarget(name: "ExteraExportTests", dependencies: ["ExteraExport"])]
)
