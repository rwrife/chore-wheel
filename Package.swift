// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ChoreWheelCore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "ChoreWheelCore", targets: ["ChoreWheelCore"]),
    ],
    targets: [
        .target(
            name: "ChoreWheelCore",
            path: "Sources/ChoreWheel",
            exclude: ["App"]
        ),
        .testTarget(
            name: "ChoreWheelTests",
            dependencies: ["ChoreWheelCore"],
            path: "Tests/ChoreWheelTests"
        ),
    ]
)
