import XCTest
@testable import DevSpaceCore

final class ShellIntegrationTests: XCTestCase {
    func testSnippetEmitsOSC7ForBothShells() {
        let s = ShellIntegration.snippet
        // ghostty core drops OSC 7 URLs with a missing or non-local host —
        // the report MUST use file://localhost.
        XCTAssertTrue(s.contains("\\033]7;file://localhost"))
        XCTAssertTrue(s.contains("ZSH_VERSION"))  // zsh precmd hook
        XCTAssertTrue(s.contains("BASH_VERSION")) // bash PROMPT_COMMAND hook
        XCTAssertTrue(s.hasPrefix(ShellIntegration.beginMarker))
        XCTAssertTrue(s.hasSuffix(ShellIntegration.endMarker))
    }

    func testInjectScriptReplacesExistingBlockAndTargetsBothRCFiles() {
        let script = ShellIntegration.injectScript(podID: "wc-1", token: "sekret")
        // Old marker blocks are deleted before appending, so snippet updates
        // self-upgrade instead of staying pinned to the first-injected version.
        XCTAssertTrue(script.contains("sed -i"))
        XCTAssertTrue(script.contains(".bashrc"))
        XCTAssertTrue(script.contains(".zshrc"))
        XCTAssertTrue(script.contains("base64 -d >>")) // append, never overwrite
    }

    func testInjectScriptPayloadRoundTripsOSC7AndDideHelper() throws {
        let decoded = try injectedPayload(
            from: ShellIntegration.injectScript(podID: "wc-1", token: "sekret-token")
        )

        XCTAssertTrue(decoded.contains(ShellIntegration.beginMarker))
        XCTAssertTrue(decoded.contains(ShellIntegration.endMarker))
        XCTAssertTrue(decoded.contains("__devspace_osc7()"))
        XCTAssertTrue(decoded.contains("PROMPT_COMMAND"))
        XCTAssertTrue(decoded.contains("dide()"))
        XCTAssertTrue(decoded.contains("if [ \"$#\" -gt 1 ]"))
        XCTAssertTrue(decoded.contains("cd -- \"$target\""))
        XCTAssertTrue(decoded.contains("pwd -P"))
        XCTAssertTrue(decoded.contains("path_b64"))
        XCTAssertTrue(decoded.contains("pod_id"))
        XCTAssertTrue(decoded.contains("wc-1"))
        XCTAssertTrue(decoded.contains("token"))
        XCTAssertTrue(decoded.contains("sekret-token"))
        XCTAssertTrue(decoded.contains("http://localhost:\(SSH.podForwardPort)/dide"))
    }

    func testDideHelperPostsCanonicalJSONForDefaultAbsoluteAndRelativeTargetsInBashAndZsh() throws {
        let harness = try DideHarness(
            snippet: injectedPayload(
                from: ShellIntegration.injectScript(podID: "wc-1", token: "sekret-token")
            )
        )
        defer { harness.cleanup() }

        for shell in try shellSpecs() {
            let defaultResult = try harness.run(
                shell: shell,
                arguments: [],
                currentDirectory: harness.cwdSymlink
            )
            XCTAssertEqual(defaultResult.status, 0, "\(shell.name) default stderr: \(defaultResult.stderr)")
            XCTAssertTrue(
                defaultResult.stdout.contains("dide: opening \(harness.canonicalPath(for: harness.cwdReal))"),
                "\(shell.name) default stdout: \(defaultResult.stdout)"
            )
            XCTAssertEqual(try defaultResult.decodedPath(), harness.canonicalPath(for: harness.cwdReal))
            XCTAssertEqual(try defaultResult.payloadValue("pod_id"), "wc-1")
            XCTAssertEqual(try defaultResult.payloadValue("token"), "sekret-token")
            XCTAssertTrue(defaultResult.curlArguments.contains("-d"), "\(shell.name) curl args: \(defaultResult.curlArguments)")
            XCTAssertTrue(
                defaultResult.curlArguments.contains("--max-time"),
                "\(shell.name) curl args: \(defaultResult.curlArguments)"
            )
            XCTAssertTrue(defaultResult.curlArguments.contains("2"), "\(shell.name) curl args: \(defaultResult.curlArguments)")
            XCTAssertTrue(
                defaultResult.curlArguments.contains("http://localhost:\(SSH.podForwardPort)/dide"),
                "\(shell.name) curl args: \(defaultResult.curlArguments)"
            )

            let absoluteResult = try harness.run(
                shell: shell,
                arguments: [harness.absoluteTargetSymlink.path],
                currentDirectory: harness.cwdReal
            )
            XCTAssertEqual(absoluteResult.status, 0, "\(shell.name) absolute stderr: \(absoluteResult.stderr)")
            XCTAssertEqual(
                try absoluteResult.decodedPath(),
                harness.canonicalPath(for: harness.absoluteTargetReal)
            )

            let relativeResult = try harness.run(
                shell: shell,
                arguments: ["relative-link"],
                currentDirectory: harness.relativeParent
            )
            XCTAssertEqual(relativeResult.status, 0, "\(shell.name) relative stderr: \(relativeResult.stderr)")
            XCTAssertEqual(
                try relativeResult.decodedPath(),
                harness.canonicalPath(for: harness.relativeTargetReal)
            )
        }
    }

    func testDideHelperRejectsTooManyArgsEmptyTargetAndNonDirectoryTargetInBashAndZsh() throws {
        let harness = try DideHarness(
            snippet: injectedPayload(
                from: ShellIntegration.injectScript(podID: "wc-1", token: "sekret-token")
            )
        )
        defer { harness.cleanup() }

        for shell in try shellSpecs() {
            let tooManyArgs = try harness.run(
                shell: shell,
                arguments: ["one", "two"],
                currentDirectory: harness.cwdReal
            )
            XCTAssertEqual(tooManyArgs.status, 64, "\(shell.name) stderr: \(tooManyArgs.stderr)")
            XCTAssertTrue(tooManyArgs.stderr.contains("usage: dide [path]"), "\(shell.name) stderr: \(tooManyArgs.stderr)")
            XCTAssertNil(tooManyArgs.payload, "\(shell.name) should not emit JSON for too many args")

            let emptyTarget = try harness.run(
                shell: shell,
                arguments: [""],
                currentDirectory: harness.cwdReal
            )
            XCTAssertNotEqual(emptyTarget.status, 0, "\(shell.name) empty target unexpectedly succeeded")
            XCTAssertTrue(emptyTarget.stderr.contains("dide: path must not be empty"), "\(shell.name) stderr: \(emptyTarget.stderr)")
            XCTAssertNil(emptyTarget.payload, "\(shell.name) should not emit JSON for an empty target")

            let nonDirectory = try harness.run(
                shell: shell,
                arguments: [harness.plainFile.path],
                currentDirectory: harness.cwdReal
            )
            XCTAssertNotEqual(nonDirectory.status, 0, "\(shell.name) non-directory unexpectedly succeeded")
            XCTAssertTrue(nonDirectory.stderr.contains("dide: could not resolve path"), "\(shell.name) stderr: \(nonDirectory.stderr)")
            XCTAssertNil(nonDirectory.payload, "\(shell.name) should not emit JSON for a file target")
        }
    }

    func testDideHelperFailsWhenBase64EncodingFailsInBashAndZsh() throws {
        let harness = try DideHarness(
            snippet: injectedPayload(
                from: ShellIntegration.injectScript(podID: "wc-1", token: "sekret-token")
            )
        )
        defer { harness.cleanup() }

        for shell in try shellSpecs() {
            let result = try harness.run(
                shell: shell,
                arguments: [],
                currentDirectory: harness.cwdReal,
                failBase64: true
            )
            XCTAssertNotEqual(result.status, 0, "\(shell.name) base64 failure unexpectedly succeeded")
            XCTAssertTrue(result.stderr.contains("dide: could not encode path"), "\(shell.name) stderr: \(result.stderr)")
            XCTAssertNil(result.payload, "\(shell.name) should not emit JSON when base64 fails")
        }
    }

    func testInjectScriptWithoutTokenOmitsDideHelper() throws {
        let decoded = try injectedPayload(
            from: ShellIntegration.injectScript(podID: "wc-1", token: "")
        )

        XCTAssertTrue(decoded.contains(ShellIntegration.snippet))
        XCTAssertFalse(decoded.contains("dide()"))
        XCTAssertFalse(decoded.contains("/dide"))
        XCTAssertFalse(decoded.contains("\"token\":"))
    }

    func testInjectRejectsInvalidPodID() {
        struct NoRun: CommandRunning {
            func run(_ args: [String]) throws -> String {
                XCTFail("must not run for an invalid id")
                return ""
            }
        }
        XCTAssertThrowsError(try ShellIntegration.inject(NoRun(), podID: "-rf", token: "sekret"))
    }

    func testInjectRunsDevpodSSHForValidID() throws {
        final class Recorder: @unchecked Sendable, CommandRunning {
            var calls: [[String]] = []
            func run(_ args: [String]) throws -> String {
                calls.append(args)
                return ""
            }
        }
        let r = Recorder()
        try ShellIntegration.inject(r, podID: "wc-1", token: "sekret")
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls[0], [
            "ssh", "--command", ShellIntegration.injectScript(podID: "wc-1", token: "sekret"),
            "--start-services=false", "--", "wc-1",
        ])
    }

    private func injectedPayload(from script: String) throws -> String {
        let echoRange = try XCTUnwrap(script.range(of: "echo "))
        let payloadStart = script[echoRange.upperBound...]
        let b64 = try XCTUnwrap(payloadStart.split(separator: " ").first)
        return String(
            decoding: try XCTUnwrap(Data(base64Encoded: String(b64))),
            as: UTF8.self
        )
    }

    private func shellSpecs() throws -> [ShellSpec] {
        let bashCandidates = ["/opt/homebrew/bin/bash", "/bin/bash"]
        let bash = try XCTUnwrap(bashCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }))
        let zsh = try XCTUnwrap(["/bin/zsh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }))
        return [
            ShellSpec(name: "bash", path: bash),
            ShellSpec(name: "zsh", path: zsh),
        ]
    }
}

private struct ShellSpec {
    let name: String
    let path: String
}

private struct DideRunResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let payload: String?
    let curlArguments: [String]

    func payloadValue(_ key: String) throws -> String {
        let json = try payloadJSON()
        return try XCTUnwrap(json[key])
    }

    func decodedPath() throws -> String {
        let b64 = try payloadValue("path_b64")
        let data = try XCTUnwrap(Data(base64Encoded: b64))
        return String(decoding: data, as: UTF8.self)
    }

    private func payloadJSON() throws -> [String: String] {
        let payload = try XCTUnwrap(payload)
        let data = Data(payload.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: String])
    }
}

private final class DideHarness {
    let root: URL
    let snippetFile: URL
    let binDir: URL
    let cwdReal: URL
    let cwdSymlink: URL
    let absoluteTargetReal: URL
    let absoluteTargetSymlink: URL
    let relativeParent: URL
    let relativeTargetReal: URL
    let plainFile: URL

    init(snippet: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devspace-dide-\(UUID().uuidString)")
        binDir = root.appendingPathComponent("bin", isDirectory: true)
        snippetFile = root.appendingPathComponent("snippet.sh")
        cwdReal = root.appendingPathComponent("cwd-real", isDirectory: true)
        cwdSymlink = root.appendingPathComponent("cwd-link", isDirectory: true)
        absoluteTargetReal = root.appendingPathComponent("absolute-real", isDirectory: true)
        absoluteTargetSymlink = root.appendingPathComponent("absolute-link", isDirectory: true)
        relativeParent = root.appendingPathComponent("relative-parent", isDirectory: true)
        relativeTargetReal = relativeParent.appendingPathComponent("relative-real", isDirectory: true)
        plainFile = root.appendingPathComponent("not-a-directory.txt")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwdReal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: absoluteTargetReal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relativeParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relativeTargetReal, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cwdSymlink, withDestinationURL: cwdReal)
        try FileManager.default.createSymbolicLink(at: absoluteTargetSymlink, withDestinationURL: absoluteTargetReal)
        try FileManager.default.createSymbolicLink(
            at: relativeParent.appendingPathComponent("relative-link", isDirectory: true),
            withDestinationURL: relativeTargetReal
        )
        try "fixture".write(to: plainFile, atomically: true, encoding: .utf8)
        try snippet.write(to: snippetFile, atomically: true, encoding: .utf8)
        try writeExecutable(
            """
            #!/bin/sh
            if [ "${DIDE_TEST_BASE64_FAIL:-0}" = "1" ]; then
              echo "stub base64 failure" >&2
              exit 1
            fi
            exec /usr/bin/base64 "$@"
            """,
            to: binDir.appendingPathComponent("base64")
        )
        try writeExecutable(
            """
            #!/bin/sh
            args_file=$DIDE_TEST_CURL_ARGS_FILE
            payload_file=$DIDE_TEST_PAYLOAD_FILE
            : > "$args_file"
            while [ "$#" -gt 0 ]; do
              arg=$1
              printf '%s\n' "$arg" >> "$args_file"
              shift
              if [ "$arg" = "-d" ] && [ "$#" -gt 0 ]; then
                printf '%s' "$1" > "$payload_file"
                printf '%s\n' "$1" >> "$args_file"
                shift
              fi
            done
            exit 0
            """,
            to: binDir.appendingPathComponent("curl")
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func canonicalPath(for url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        // Darwin's /var is a symlink to /private/var, and `pwd -P` (which the
        // helper intentionally uses) reports the physical /private path.
        return path == "/var" || path.hasPrefix("/var/") ? "/private" + path : path
    }

    func run(
        shell: ShellSpec,
        arguments: [String],
        currentDirectory: URL,
        failBase64: Bool = false
    ) throws -> DideRunResult {
        let payloadFile = root.appendingPathComponent("payload-\(UUID().uuidString).json")
        let argsFile = root.appendingPathComponent("curl-args-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.path)
        process.currentDirectoryURL = currentDirectory
        process.arguments = ["-c", ". \"$SNIPPET\"; dide \"$@\"", "dide-test"] + arguments
        process.environment = [
            "HOME": root.path,
            "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "SNIPPET": snippetFile.path,
            "DIDE_TEST_PAYLOAD_FILE": payloadFile.path,
            "DIDE_TEST_CURL_ARGS_FILE": argsFile.path,
            "DIDE_TEST_BASE64_FAIL": failBase64 ? "1" : "0",
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(
            decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let stderr = String(
            decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let payload = try? String(contentsOf: payloadFile, encoding: .utf8)
        let curlArgsText = (try? String(contentsOf: argsFile, encoding: .utf8)) ?? ""

        return DideRunResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            payload: payload,
            curlArguments: curlArgsText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
