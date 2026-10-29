// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RenderEngine",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RenderEngine", targets: ["RenderEngine"]),
    ],
    dependencies: [
        .package(path: "../EditModel"),
    ],
    targets: [
        .target(
            name: "RenderEngine",
            dependencies: ["EditModel"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "RenderEngineTests",
            dependencies: ["RenderEngine"]
        ),
    ]
)
