// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LibraryKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
    ],
    dependencies: [
        .package(path: "../ImageIOKit"),
        // SQLite catalog (MIT). See docs/catalogue.md for why GRDB rather than SwiftData.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
    ],
    targets: [
        .target(
            name: "LibraryKit",
            dependencies: [
                "ImageIOKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
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
