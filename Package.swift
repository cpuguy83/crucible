// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crucible",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "BuildKitCore", targets: ["BuildKitCore"]),
        .library(name: "BuildKitContainerization", targets: ["BuildKitContainerization"]),
        .library(name: "BuildKitContainerCLI", targets: ["BuildKitContainerCLI"]),
    ],
    dependencies: [
        // Apple's Containerization framework. Pinned to next-minor for source stability
        // per upstream guidance (0.x is unstable across minors).
        .package(url: "https://github.com/apple/containerization.git", .upToNextMinor(from: "0.31.0")),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.2.0"),
    ],
    targets: [
        // Headless, unit-testable supervisor/protocol surface plus typed BuildKit control client.
        .target(
            name: "BuildKitCore",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            path: "Sources/BuildKitCore",
            exclude: [
                "Protos"
            ]
        ),
        // Default backend: links apple/containerization directly.
        .target(
            name: "BuildKitContainerization",
            dependencies: [
                "BuildKitCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
            ],
            path: "Sources/BuildKitContainerization"
        ),
        // Opt-in backend: shells out to the `container` CLI from apple/container.
        .target(
            name: "BuildKitContainerCLI",
            dependencies: ["BuildKitCore"],
            path: "Sources/BuildKitContainerCLI"
        ),

        .testTarget(
            name: "BuildKitCoreTests",
            dependencies: ["BuildKitCore"],
            path: "Tests/BuildKitCoreTests"
        ),
        .testTarget(
            name: "BuildKitContainerizationTests",
            dependencies: ["BuildKitContainerization"],
            path: "Tests/BuildKitContainerizationTests"
        ),
        .testTarget(
            name: "BuildKitContainerCLITests",
            dependencies: ["BuildKitContainerCLI"],
            path: "Tests/BuildKitContainerCLITests"
        ),

        // Headless smoke driver. Sign with the virtualization entitlement
        // before running:
        //   codesign --force --sign - --entitlements Apps/Crucible/Resources/Crucible.entitlements .build/debug/crucibled
        .executableTarget(
            name: "crucibled",
            dependencies: [
                "BuildKitCore",
                "BuildKitContainerization",
                "BuildKitContainerCLI",
            ],
            path: "Sources/crucibled"
        ),
    ]
)
