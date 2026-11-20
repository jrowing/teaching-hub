// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TeachingHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TeachingHub", targets: ["TeachingHub"])
    ],
    targets: [
        .executableTarget(
            name: "TeachingHub",
            path: "Sources/TeachingHub"
        )
    ]
)
