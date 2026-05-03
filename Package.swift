// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorldCitiesDB",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "WorldCitiesDB",
            targets: ["WorldCitiesDB"]
        ),
    ],
    targets: [
        .target(
            name: "WorldCitiesDB",
            resources: [
                .copy("Resources"),
            ]
        ),
        .executableTarget(
            name: "BuildDB",
            dependencies: ["WorldCitiesDB"]
        ),
        .executableTarget(
            name: "Demo",
            dependencies: ["WorldCitiesDB"]
        ),
        .executableTarget(
            name: "Benchmark",
            dependencies: ["WorldCitiesDB"]
        ),
        .testTarget(
            name: "WorldCitiesDBTests",
            dependencies: ["WorldCitiesDB"]
        ),
    ]
)
