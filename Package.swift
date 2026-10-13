// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacClean",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacClean", targets: ["MacClean"])],
    targets: [.executableTarget(name: "MacClean")]
)
