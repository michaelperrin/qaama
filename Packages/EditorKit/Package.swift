// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EditorKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "EditorKit", targets: ["EditorKit"]),
    ],
    dependencies: [
        .package(path: "../EditModel"),
        .package(path: "../LibraryKit"),
        .package(path: "../RenderEngine"),
    ],
    targets: [
        .target(
            name: "EditorKit",
            dependencies: ["EditModel", "LibraryKit", "RenderEngine"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "EditorKitTests",
            dependencies: ["EditorKit"]
        ),
    ]
)
