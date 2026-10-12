// swift-tools-version: 5.9
import PackageDescription

var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    // C shims for PTY ops not callable from Swift (forkpty in <util.h>;
    // ioctl is variadic).
    .target(
        name: "CPTY",
        path: "Sources/CPTY",
        linkerSettings: [
            .linkedLibrary("util", .when(platforms: [.linux]))
        ]
    ),
    // Portable logic (devpod/poller/notify/hooks/layout/path_env land here
    // in later stacks). Kept separate so tests can @testable import it
    // without pulling in the SwiftUI app.
    .target(
        name: "DevSpaceCore",
        dependencies: ["CPTY"],
        path: "Sources/Core"
    ),
    .testTarget(
        name: "DevSpaceCoreTests",
        dependencies: ["DevSpaceCore"],
        path: "Tests/Core"
    ),
]

#if os(macOS)
dependencies.append(
    .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.2.7")
)
targets += [
    // The SwiftUI app. Assembled into a .app bundle by the Makefile.
    .executableTarget(
        name: "DevSpaceApp",
        dependencies: [
            "DevSpaceCore",
            .product(name: "GhosttyKit", package: "libghostty-spm"),
            .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            .product(name: "GhosttyTheme", package: "libghostty-spm"),
        ],
        path: "Sources/App"
    ),
    .testTarget(
        name: "DevSpaceAppTests",
        dependencies: ["DevSpaceApp"],
        path: "Tests/App"
    ),
]
#elseif os(Linux)
targets += [
    // Child process owned by the GTK frontend. Its stdin/stdout are reserved
    // for the private control protocol; terminal bytes stay in Ghostty.
    .executableTarget(
        name: "DevSpaceLinuxBackend",
        dependencies: ["DevSpaceCore"],
        path: "Sources/LinuxBackend"
    ),
]
#endif

let package = Package(
    name: "DevSpace",
    platforms: [.macOS(.v14)],
    dependencies: dependencies,
    targets: targets
)
