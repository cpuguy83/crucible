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
    ],
    targets: [
        // Pure, dependency-free supervisor + protocol surface. Headless and unit-testable.
        .target(
            name: "BuildKitCore",
            path: "Sources/BuildKitCore"
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

        // Headless smoke driver. Sign with the virtualization entitlement
        // before running:
        //   codesign --force --sign - --entitlements Apps/Crucible/Resources/Crucible.entitlements .build/debug/crucibled
        .executableTarget(
            name: "crucibled",
            dependencies: [
                "BuildKitCore",
                "BuildKitContainerization",
            ],
            path: "Sources/crucibled"
        ),
    ]
)
