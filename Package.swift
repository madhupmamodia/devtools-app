// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "devtools-app",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ws", targets: ["ws"]),
        .executable(name: "DevTools", targets: ["DevTools"])
    ],
    targets: [
        .target(
            name: "WorkspaceCore",
            path: "Sources/WorkspaceCore"
        ),
        .executableTarget(
            name: "ws",
            dependencies: ["WorkspaceCore"],
            path: "Sources/ws"
        ),
        .executableTarget(
            name: "DevTools",
            dependencies: ["WorkspaceCore"],
            path: "Sources/DevTools"
        )
    ]
)
