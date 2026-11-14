// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portly",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PortlyApp", targets: ["PortlyApp"]),
        .executable(name: "portly", targets: ["PortlyCLI"]),
        .library(name: "PortlyCore", targets: ["PortlyCore"]),
    ],
    dependencies: [
        // 1.99.x is the 2.0 preview, which changes the terminal API: stay on 1.x until it ships.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", "1.20.0"..<"1.99.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "PortlyCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PortlyApp",
            dependencies: [
                "PortlyCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [
                .copy("Resources/Icons"),
                .copy("Resources/icon-catalog.json"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PortlyCLI",
            dependencies: [
                "PortlyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PortlyAppTests",
            dependencies: ["PortlyApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
