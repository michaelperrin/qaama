// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EditModel",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "EditModel", targets: ["EditModel"]),
    ],
    targets: [
        .target(
            name: "EditModel",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "EditModelTests",
            dependencies: ["EditModel"]
        ),
    ]
)
