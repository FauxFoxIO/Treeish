// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Treeish",
    platforms: [
        .iOS("17.4"),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Treeish", targets: ["Treeish"]),
    ],
    targets: [
        .target(
            name: "TreeishCore",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TreeishFileSystem",
            dependencies: ["TreeishCore"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TreeishObjects",
            dependencies: ["TreeishCore", "TreeishFileSystem"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TreeishIndex",
            dependencies: ["TreeishCore", "TreeishFileSystem"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TreeishPacks",
            dependencies: ["TreeishCore", "TreeishObjects"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TreeishProtocol",
            dependencies: ["TreeishCore"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TreeishGraph",
            dependencies: ["TreeishCore", "TreeishObjects"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TreeishDiff",
            dependencies: ["TreeishCore"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "TreeishHTTP",
            dependencies: ["TreeishProtocol"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "Treeish",
            dependencies: [
                "TreeishCore", "TreeishFileSystem", "TreeishObjects",
                "TreeishIndex", "TreeishPacks", "TreeishProtocol",
                "TreeishGraph", "TreeishDiff",
                "TreeishHTTP",
            ],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "TreeishTests",
            dependencies: ["Treeish", "TreeishCore", "TreeishHTTP", "TreeishObjects", "TreeishPacks", "TreeishProtocol"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "TreeishFormatTests",
            dependencies: [
                "TreeishCore", "TreeishObjects", "TreeishIndex", "TreeishPacks",
                "TreeishProtocol",
                "TreeishGraph", "TreeishDiff",
                "TreeishHTTP",
            ],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "TreeishInteroperabilityTests",
            dependencies: ["Treeish"],
            swiftSettings: strictConcurrency
        ),
    ],
    swiftLanguageModes: [.v6]
)

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]
