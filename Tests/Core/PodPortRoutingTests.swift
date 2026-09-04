import Foundation
import XCTest
@testable import DevSpaceCore

final class PodPortRoutingTests: XCTestCase {
    func testResolverSelectsLiveProductionPort() throws {
        XCTAssertEqual(try resolve(livePorts: [8765]).stdout, "8765")
    }

    func testResolverFallsBackToLiveDevelopmentPort() throws {
        XCTAssertEqual(try resolve(livePorts: [8766]).stdout, "8766")
    }

    func testResolverPrefersProductionWithoutProbingDevelopment() throws {
        let result = try resolve(livePorts: [8765, 8766])
        XCTAssertEqual(result.stdout, "8765")
        XCTAssertEqual(result.probedPorts, ["8765"])
    }

    func testResolverFailsWhenNeitherPortIsLive() throws {
        XCTAssertNotEqual(try resolve(livePorts: []).status, 0)
    }

    func testResolverUsesConfiguredProductionPort() throws {
        XCTAssertEqual(
            try resolve(
                livePorts: [9876],
                environment: ["DEVSPACE_PROD_POD_FORWARD_PORT": "9876"]
            ).stdout,
            "9876"
        )
    }

    func testResolverRejectsMalformedConfiguredPort() throws {
        XCTAssertNotEqual(
            try resolve(
                livePorts: [8765],
                environment: ["DEVSPACE_PROD_POD_FORWARD_PORT": "8765/x"]
            ).status,
            0
        )
    }

    private func resolve(
        livePorts: [UInt16],
        environment: [String: String] = [:]
    ) throws -> ResolverResult {
        let harness = try PortResolverHarness()
        defer { harness.cleanup() }
        return try harness.resolve(livePorts: livePorts, environment: environment)
    }
}

private struct ResolverResult {
    let status: Int32
    let stdout: String
    let probedPorts: [String]
}

private final class PortResolverHarness {
    private let root: URL
    private let resolverFile: URL
    private let binDir: URL
    private let traceFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devspace-port-resolver-\(UUID().uuidString)")
        resolverFile = root.appendingPathComponent("resolver.sh")
        binDir = root.appendingPathComponent("bin", isDirectory: true)
        traceFile = root.appendingPathComponent("curl-trace.txt")

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try PodPortRouting.resolverShell.write(to: resolverFile, atomically: true, encoding: .utf8)
        try writeExecutable(
            """
            #!/bin/sh
            for arg in "$@"; do url=$arg; done
            port=${url#http://localhost:}
            port=${port%%/*}
            printf '%s\\n' "$port" >> "$DEVSPACE_TEST_CURL_TRACE"
            case ",$DEVSPACE_TEST_LIVE_PORTS," in
              *,"$port",*) exit 0 ;;
              *) exit 1 ;;
            esac
            """,
            to: binDir.appendingPathComponent("curl")
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func resolve(livePorts: [UInt16], environment: [String: String]) throws -> ResolverResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ". \"$DEVSPACE_TEST_RESOLVER\"; __devspace_resolve_port"]
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "DEVSPACE_TEST_CURL_TRACE": traceFile.path,
            "DEVSPACE_TEST_LIVE_PORTS": livePorts.map(String.init).joined(separator: ","),
            "DEVSPACE_TEST_RESOLVER": resolverFile.path,
        ].merging(environment) { _, override in override }

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .newlines)
        let trace = (try? String(contentsOf: traceFile, encoding: .utf8)) ?? ""

        return ResolverResult(
            status: process.terminationStatus,
            stdout: output,
            probedPorts: trace.split(separator: "\n").map(String.init)
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
