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
        .package(path: "../ImageIOKit"),
    ],
    targets: [
        // The fill behind the retouch tool: tight loops over pixels, tens of milliseconds optimized
        // and tens of seconds not. The app is developed and tested in Debug builds, so this target
        // alone is always optimized. Pure Swift, no actor isolation.
        .target(
            name: "HealingFill",
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "RenderEngine",
            dependencies: ["EditModel", "ImageIOKit", "HealingFill"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "HealingFillTests",
            dependencies: ["HealingFill"]
        ),
        .testTarget(
            name: "RenderEngineTests",
            dependencies: ["RenderEngine"]
        ),
    ]
)
