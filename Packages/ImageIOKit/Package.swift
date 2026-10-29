// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ImageIOKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ImageIOKit", targets: ["ImageIOKit"]),
    ],
    targets: [
        .target(
            name: "ImageIOKit",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "ImageIOKitTests",
            dependencies: ["ImageIOKit"]
        ),
    ]
)
