// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevSpace",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.7"),
    ],
    targets: [
        // C shims for PTY ops not callable from Swift (forkpty in <util.h>;
        // ioctl is variadic).
        .target(
            name: "CPTY",
            path: "Sources/CPTY"
        ),
        // Portable logic (devpod/poller/notify/hooks/layout/path_env land here
        // in later stacks). Kept separate so tests can @testable import it
        // without pulling in the SwiftUI app.
        .target(
            name: "DevSpaceCore",
            dependencies: ["CPTY"],
            path: "Sources/Core"
        ),
        // The SwiftUI app. Assembled into a .app bundle by the Makefile.
        .executableTarget(
            name: "DevSpaceApp",
            dependencies: [
                "DevSpaceCore",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/App"
        ),
        .testTarget(
            name: "DevSpaceCoreTests",
            dependencies: ["DevSpaceCore"],
            path: "Tests/Core"
        ),
    ]
)
