// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rummage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Rummage",
            path: "Sources/Rummage",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Quartz"),
            ]
        )
    ]
)
