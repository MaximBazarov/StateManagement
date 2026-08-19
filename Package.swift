// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StateManagement",
    platforms: [
        .macOS(.v12),
        .iOS(.v17),

    ],
    products: [
        .library(
            name: "StateManagement",
            targets: ["StateManagement"]
        ),
        .library(
            name: "StateManagementTestingSupport",
            targets: ["StateManagementTestingSupport"]
        )
    ],
    traits: [
        .default(enabledTraits: []),
        .trait(name: "Telemetry"),
        .trait(name: "TelemetryInternal"),
    ],
    targets: [
        // MARK: - StateManagement -
        .target(
            name: "StateManagement",
            path: "Sources",
            swiftSettings: [
                .define("STATE_MANAGEMENT_TELEMETRY", .when(traits: ["Telemetry"])),
                .define("STATE_MANAGEMENT_TELEMETRY_INTERNAL", .when(traits: ["TelemetryInternal"]))
            ]
        ),
        .target(
            name: "StateManagementTestingSupport",
            dependencies: ["StateManagement"],
            path: "TestingSupport",
            swiftSettings: [
                .define("STATE_MANAGEMENT_TELEMETRY", .when(traits: ["Telemetry"])),
                .define("STATE_MANAGEMENT_TELEMETRY_INTERNAL", .when(traits: ["TelemetryInternal"]))
            ]
        ),
        .testTarget(
            name: "StateManagement_Tests",
            dependencies: [
                "StateManagement",
                "StateManagementTestingSupport"
            ],
            path: "Tests",
            swiftSettings: [
                .define("STATE_MANAGEMENT_TELEMETRY", .when(traits: ["Telemetry"])),
                .define("STATE_MANAGEMENT_TELEMETRY_INTERNAL", .when(traits: ["TelemetryInternal"]))
            ]
        ),
    ]
)
