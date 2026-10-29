// swift-tools-version:5.9
// The platform-independent part of the iPad app: notebooks, the merge rules
// shared with openpad/notebook.py and web/model.js, and the sync protocol's
// pure logic. Builds and tests on Linux too (swift test).

import PackageDescription

let package = Package(
    name: "OpenPadCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "OpenPadCore", targets: ["OpenPadCore"])],
    targets: [
        .target(name: "OpenPadCore"),
        .testTarget(name: "OpenPadCoreTests", dependencies: ["OpenPadCore"], resources: [.copy("Resources")]),
    ]
)
