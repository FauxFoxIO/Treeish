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
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.101.3"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssh.git",
            exact: "0.14.1"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-transport-services.git",
            exact: "1.28.0"
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "4.5.1"
        ),
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
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(
                    name: "NIOTransportServices",
                    package: "swift-nio-transport-services"
                ),
            ],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "TreeishTests",
            dependencies: ["Treeish", "TreeishCore", "TreeishFileSystem", "TreeishHTTP", "TreeishObjects", "TreeishPacks", "TreeishProtocol"],
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
