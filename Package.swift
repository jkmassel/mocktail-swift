// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MockWebServer",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "MockWebServer", targets: ["MockWebServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.4.3"),
    ],
    targets: [
        .target(
            name: "MockWebServer",
            resources: [.copy("Resources/Certificates")]
        ),
        .testTarget(
            name: "MockWebServerTests",
            dependencies: ["MockWebServer"]
        ),
        .testTarget(
            name: "ExampleTests",
            dependencies: ["MockWebServer"],
            path: "Examples"
        ),
    ]
)
