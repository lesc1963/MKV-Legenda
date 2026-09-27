// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MKVLegenda",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MKVLegenda", targets: ["MKVLegenda"])
    ],
    targets: [
        .executableTarget(
            name: "MKVLegenda",
            path: "Sources/MKVLegenda",
            resources: [.copy("Resources/lesc-logo.png")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
