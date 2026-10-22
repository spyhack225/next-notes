// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "PhononASR", platforms: [.macOS(.v15)], products: [.library(name: "PhononCoreML", targets: ["PhononCoreML"])], targets: [.binaryTarget(name: "PhononTDT", path: "Binaries/PhononTDT.xcframework"), .target(name: "PhononCoreML", dependencies: ["PhononTDT"], path: "Sources/PhononCoreML")])
