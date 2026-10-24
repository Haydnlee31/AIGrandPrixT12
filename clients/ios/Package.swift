// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CommonThreadKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "CommonThreadKit", targets: ["CommonThreadKit"])],
    targets: [
        .target(name: "CommonThreadKit"),
        .testTarget(name: "CommonThreadKitTests", dependencies: ["CommonThreadKit"], resources: [.process("Fixtures")])
    ]
)
