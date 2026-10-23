// swift-tools-version: 5.9
import PackageDescription
import Foundation

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
let ghosttyEnabled = ProcessInfo.processInfo.environment["DEVSPACE_LINUX_TERMINAL"] == "ghostty"
var linuxAppDependencies: [Target.Dependency] = ["DevSpaceCore", "CGTK"]
var linuxAppSettings: [SwiftSetting] = []
if ghosttyEnabled {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    let skia = ProcessInfo.processInfo.environment["SKIA_SOURCE"] ?? "\(root)/.tmp/ghostty-skia/skia"
    let ghostty = ProcessInfo.processInfo.environment["GHOSTTY_VT_PREFIX"] ?? "\(root)/.tmp/ghostty-skia/ghostty-vt"
    let nativeIncludes = ["-Xcc", "-I\(skia)", "-Xcc", "-I\(ghostty)/include"]
    let skiaSettings: [SwiftSetting] = [.interoperabilityMode(.Cxx), .unsafeFlags(nativeIncludes + [
        "-Xcc", "-std=c++20", "-Xcc", "-fapinotes-modules", "-Xcc", "-DNDEBUG", "-Xcc", "-DSK_R32_SHIFT=16"
    ])]
    targets += [
        .systemLibrary(name: "CGhosttyVT", path: "Sources/GhosttyVTInterop"),
        .systemLibrary(name: "CSkia", path: "Sources/SkiaInterop"),
        .systemLibrary(name: "CHarfBuzz", path: "Sources/HarfBuzzInterop", pkgConfig: "harfbuzz"),
        .systemLibrary(name: "CGPU", path: "Sources/LinuxGPU", pkgConfig: "gl"),
        .target(name: "DevSpaceGhosttyVT", dependencies: ["CGhosttyVT"], path: "Sources/GhosttyVT",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(ghostty)/include"])],
            linkerSettings: [.unsafeFlags(["\(ghostty)/lib/libghostty-vt.a"])]),
        .target(name: "DevSpaceSkiaRenderer", dependencies: ["DevSpaceGhosttyVT", "CSkia", "CHarfBuzz"],
            path: "Sources/SkiaRenderer", swiftSettings: skiaSettings,
            linkerSettings: [.unsafeFlags(["-L\(skia)/out/DevSpace"]), .linkedLibrary("skia"),
                .linkedLibrary("skcms"), .linkedLibrary("stdc++"), .linkedLibrary("fontconfig"),
                .linkedLibrary("freetype"), .linkedLibrary("GL"), .linkedLibrary("EGL"),
                .linkedLibrary("GLESv2"), .linkedLibrary("dl")]),
        .testTarget(name: "DevSpaceGhosttyFrontendTests", dependencies: ["DevSpaceLinuxApp"],
            path: "Tests/GhosttyFrontend", swiftSettings: skiaSettings),
    ]
    linuxAppDependencies += ["DevSpaceGhosttyVT", "DevSpaceSkiaRenderer", "CGPU"]
    linuxAppSettings = skiaSettings + [.define("DEVSPACE_GHOSTTY")]
} else { linuxAppDependencies.append("CVTE") }
targets += [
    .systemLibrary(
        name: "CGTK",
        path: "Sources/LinuxGTK",
        pkgConfig: "gtk4",
        providers: [.apt(["libgtk-4-dev"])]
    ),
    .systemLibrary(
        name: "CVTE",
        path: "Sources/LinuxVTE",
        pkgConfig: "vte-2.91-gtk4",
        providers: [.apt(["libvte-2.91-gtk4-dev"])]
    ),
    .executableTarget(
        name: "DevSpaceLinuxApp",
        dependencies: linuxAppDependencies,
        path: "Sources/LinuxApp",
        swiftSettings: linuxAppSettings
    ),
    // Child process owned by the GTK frontend. Its stdin/stdout are reserved
    // for the private control protocol; terminal bytes stay in VTE.
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
