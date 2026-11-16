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
        // Reading `.cube` LUT files and fitting them to a grid: loops over hundreds of thousands of
        // numbers, optimized in Debug too for the same reason. Pure Swift, no actor isolation.
        .target(
            name: "CubeLUT",
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "RenderEngine",
            dependencies: ["EditModel", "ImageIOKit", "HealingFill", "CubeLUT"],
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
            name: "CubeLUTTests",
            dependencies: ["CubeLUT"]
        ),
        .testTarget(
            name: "RenderEngineTests",
            dependencies: ["RenderEngine"]
        ),
    ]
)
