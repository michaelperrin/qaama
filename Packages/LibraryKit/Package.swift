// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LibraryKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
    ],
    targets: [
        .target(
            name: "LibraryKit",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "LibraryKitTests",
            dependencies: ["LibraryKit"]
        ),
    ]
)
