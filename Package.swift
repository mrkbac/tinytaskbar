// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "TinyTaskbar",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TinyTaskbar", targets: ["TinyTaskbar"])
    ],
    targets: [
        .executableTarget(
            name: "TinyTaskbar",
            path: "Sources/TinyTaskbar",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "TinyTaskbarTests",
            dependencies: ["TinyTaskbar"],
            path: "Tests/TinyTaskbarTests",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
