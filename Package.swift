// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ChoreWheelCore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "ChoreWheelCore", targets: ["ChoreWheelCore"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(
            name: "ChoreWheelCore",
            dependencies: ["CSQLite"],
            path: "Sources/ChoreWheel",
            exclude: ["App"]
        ),
        .testTarget(
            name: "ChoreWheelTests",
            dependencies: ["ChoreWheelCore", "CSQLite"],
            path: "Tests/ChoreWheelTests"
        ),
    ]
)
