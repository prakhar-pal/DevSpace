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

    func testInjectScriptPayloadRoundTripsOSC7AndDedCompatibilityHelper() throws {
        let decoded = try injectedPayload(
            from: ShellIntegration.injectScript(podID: "wc-1", token: "sekret-token")
        )

        XCTAssertTrue(decoded.contains(ShellIntegration.beginMarker))
        XCTAssertTrue(decoded.contains(ShellIntegration.endMarker))
        XCTAssertTrue(decoded.contains("__devspace_osc7()"))
        XCTAssertTrue(decoded.contains("PROMPT_COMMAND"))
        XCTAssertTrue(decoded.contains("ded()"))
        XCTAssertTrue(decoded.contains("dide()"))
        XCTAssertTrue(decoded.contains("dide is deprecated; use ded instead"))
        XCTAssertTrue(decoded.contains("if [ \"$#\" -gt 1 ]"))
        XCTAssertTrue(decoded.contains("cd -- \"$target\""))
        XCTAssertTrue(decoded.contains("pwd -P"))
        XCTAssertTrue(decoded.contains("path_b64"))
        XCTAssertTrue(decoded.contains("pod_id"))
        XCTAssertTrue(decoded.contains("wc-1"))
        XCTAssertTrue(decoded.contains("token"))
        XCTAssertTrue(decoded.contains("sekret-token"))
        XCTAssertTrue(decoded.contains("__devspace_resolve_port()"))
        XCTAssertTrue(decoded.contains("http://localhost:$port/dide"))
    }

    func testDedHelperPostsCanonicalJSONForDefaultAbsoluteAndRelativeTargetsInBashAndZsh() throws {
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
                defaultResult.stdout.contains("ded: opening \(harness.canonicalPath(for: harness.cwdReal))"),
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
                defaultResult.curlArguments.contains("http://localhost:\(PodPortRouting.productionPort)/dide"),
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

    func testDedHelperRejectsTooManyArgsEmptyTargetAndNonDirectoryTargetInBashAndZsh() throws {
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
            XCTAssertTrue(tooManyArgs.stderr.contains("usage: ded [path]"), "\(shell.name) stderr: \(tooManyArgs.stderr)")
            XCTAssertNil(tooManyArgs.payload, "\(shell.name) should not emit JSON for too many args")

            let emptyTarget = try harness.run(
                shell: shell,
                arguments: [""],
                currentDirectory: harness.cwdReal
            )
            XCTAssertNotEqual(emptyTarget.status, 0, "\(shell.name) empty target unexpectedly succeeded")
            XCTAssertTrue(emptyTarget.stderr.contains("ded: path must not be empty"), "\(shell.name) stderr: \(emptyTarget.stderr)")
            XCTAssertNil(emptyTarget.payload, "\(shell.name) should not emit JSON for an empty target")

            let nonDirectory = try harness.run(
                shell: shell,
                arguments: [harness.plainFile.path],
                currentDirectory: harness.cwdReal
            )
            XCTAssertNotEqual(nonDirectory.status, 0, "\(shell.name) non-directory unexpectedly succeeded")
            XCTAssertTrue(nonDirectory.stderr.contains("ded: could not resolve path"), "\(shell.name) stderr: \(nonDirectory.stderr)")
            XCTAssertNil(nonDirectory.payload, "\(shell.name) should not emit JSON for a file target")
        }
    }

    func testDedHelperFailsWhenBase64EncodingFailsInBashAndZsh() throws {
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
            XCTAssertTrue(result.stderr.contains("ded: could not encode path"), "\(shell.name) stderr: \(result.stderr)")
            XCTAssertNil(result.payload, "\(shell.name) should not emit JSON when base64 fails")
        }
    }

    func testDedHelperRoutesThroughALiveTunnelInBashAndZsh() throws {
        let harness = try DideHarness(
            snippet: injectedPayload(
                from: ShellIntegration.injectScript(podID: "wc-1", token: "sekret-token")
            )
        )
        defer { harness.cleanup() }

        for shell in try shellSpecs() {
            let prod = try harness.run(
                shell: shell,
                arguments: [],
                currentDirectory: harness.cwdReal,
                livePorts: [8765, 8766]
            )
            XCTAssertEqual(prod.status, 0, "\(shell.name) production stderr: \(prod.stderr)")
            XCTAssertTrue(
                prod.curlArguments.contains("http://localhost:8765/dide"),
                "\(shell.name) production curl args: \(prod.curlArguments)"
            )

            let dev = try harness.run(
                shell: shell,
                arguments: [],
                currentDirectory: harness.cwdReal,
                livePorts: [8766]
            )
            XCTAssertEqual(dev.status, 0, "\(shell.name) development stderr: \(dev.stderr)")
            XCTAssertTrue(
                dev.curlArguments.contains("http://localhost:8766/dide"),
                "\(shell.name) development curl args: \(dev.curlArguments)"
            )

            let missing = try harness.run(
                shell: shell,
                arguments: [],
                currentDirectory: harness.cwdReal,
                livePorts: []
            )
            XCTAssertNotEqual(missing.status, 0, "\(shell.name) missing tunnel unexpectedly succeeded")
            XCTAssertTrue(
                missing.stderr.contains("ded: no DevSpace connection available"),
                "\(shell.name) missing stderr: \(missing.stderr)"
            )
            XCTAssertNil(missing.payload, "\(shell.name) should not POST without a live tunnel")

            let customProduction = try harness.run(
                shell: shell,
                arguments: [],
                currentDirectory: harness.cwdReal,
                productionPodForwardPort: "9876",
                livePorts: [9876, 8766]
            )
            XCTAssertEqual(customProduction.status, 0, "\(shell.name) custom production stderr: \(customProduction.stderr)")
            XCTAssertTrue(
                customProduction.curlArguments.contains("http://localhost:9876/dide"),
                "\(shell.name) custom production curl args: \(customProduction.curlArguments)"
            )

            let invalidProduction = try harness.run(
                shell: shell,
                arguments: [],
                currentDirectory: harness.cwdReal,
                productionPodForwardPort: "8765/x",
                developmentPodForwardPort: "9876",
                livePorts: [9876]
            )
            XCTAssertEqual(invalidProduction.status, 0, "\(shell.name) invalid production stderr: \(invalidProduction.stderr)")
            XCTAssertTrue(
                invalidProduction.curlArguments.contains("http://localhost:9876/dide"),
                "\(shell.name) invalid production curl args: \(invalidProduction.curlArguments)"
            )
        }
    }

    func testDideWarnsEveryTimeAndForwardsToDedInBashAndZsh() throws {
        let harness = try DideHarness(
            snippet: injectedPayload(
                from: ShellIntegration.injectScript(podID: "wc-1", token: "sekret-token")
            )
        )
        defer { harness.cleanup() }

        for shell in try shellSpecs() {
            let first = try harness.run(
                shell: shell,
                command: "dide",
                arguments: [harness.absoluteTargetSymlink.path],
                currentDirectory: harness.cwdReal
            )
            let repeated = try harness.runTwice(shell: shell, command: "dide", currentDirectory: harness.cwdReal)
            XCTAssertEqual(first.status, 0, "\(shell.name) stderr: \(first.stderr)")
            XCTAssertEqual(first.stderr, "dide is deprecated; use ded instead\n")
            XCTAssertEqual(
                repeated.stderr,
                "dide is deprecated; use ded instead\ndide is deprecated; use ded instead\n"
            )
            XCTAssertTrue(first.stdout.contains("ded: opening"))
            XCTAssertEqual(try first.decodedPath(), harness.canonicalPath(for: harness.absoluteTargetReal))

            let failed = try harness.run(
                shell: shell,
                command: "dide",
                arguments: ["one", "two"],
                currentDirectory: harness.cwdReal
            )
            XCTAssertEqual(failed.status, 64)
            XCTAssertEqual(
                failed.stderr,
                "dide is deprecated; use ded instead\nusage: ded [path]\n"
            )
        }
    }

    func testDedAndDideReportRequestFailuresInBashAndZsh() throws {
        let harness = try DideHarness(
            snippet: injectedPayload(
                from: ShellIntegration.injectScript(podID: "wc-1", token: "sekret-token")
            )
        )
        defer { harness.cleanup() }

        for shell in try shellSpecs() {
            let ded = try harness.run(
                shell: shell, arguments: [], currentDirectory: harness.cwdReal, failCurl: true
            )
            XCTAssertEqual(ded.status, 1)
            XCTAssertEqual(ded.stderr, "ded: request failed\n")

            let dide = try harness.run(
                shell: shell, command: "dide", arguments: [], currentDirectory: harness.cwdReal, failCurl: true
            )
            XCTAssertEqual(dide.status, ded.status)
            XCTAssertEqual(dide.stderr, "dide is deprecated; use ded instead\nded: request failed\n")
        }
    }

    func testInjectScriptWithoutTokenOmitsDideHelper() throws {
        let decoded = try injectedPayload(
            from: ShellIntegration.injectScript(podID: "wc-1", token: "")
        )

        XCTAssertTrue(decoded.contains(ShellIntegration.snippet))
        XCTAssertFalse(decoded.contains("ded()"))
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
        let bash = try XCTUnwrap(bashCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
                                 "Bash must be installed to verify shell integration")
        let zsh = try XCTUnwrap(["/bin/zsh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
                                "Zsh must be installed to verify shell integration")
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
            is_post=0
            previous=
            for arg in "$@"; do
              if [ "$previous" = "-X" ] && [ "$arg" = "POST" ]; then
                is_post=1
              fi
              previous=$arg
            done
            if [ "$is_post" != "1" ]; then
              url=
              for arg in "$@"; do
                url=$arg
              done
              port=${url#http://localhost:}
              port=${port%%/*}
              case ",${DIDE_TEST_LIVE_PORTS:-}," in
                *,"$port",*) exit 0 ;;
                *) exit 7 ;;
              esac
            fi
            if [ "${DIDE_TEST_CURL_FAIL_POST:-0}" = "1" ]; then
              exit 7
            fi
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
        command: String = "ded",
        arguments: [String],
        currentDirectory: URL,
        failBase64: Bool = false,
        failCurl: Bool = false,
        productionPodForwardPort: String? = nil,
        developmentPodForwardPort: String? = nil,
        livePorts: [UInt16] = [PodPortRouting.productionPort, PodPortRouting.developmentPort]
    ) throws -> DideRunResult {
        let payloadFile = root.appendingPathComponent("payload-\(UUID().uuidString).json")
        let argsFile = root.appendingPathComponent("curl-args-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.path)
        process.currentDirectoryURL = currentDirectory
        process.arguments = ["-c", ". \"$SNIPPET\"; \"$0\" \"$@\"", command] + arguments
        process.environment = [
            "HOME": root.path,
            "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "SNIPPET": snippetFile.path,
            "DIDE_TEST_PAYLOAD_FILE": payloadFile.path,
            "DIDE_TEST_CURL_ARGS_FILE": argsFile.path,
            "DIDE_TEST_BASE64_FAIL": failBase64 ? "1" : "0",
            "DIDE_TEST_CURL_FAIL_POST": failCurl ? "1" : "0",
            "DEVSPACE_PROD_POD_FORWARD_PORT": productionPodForwardPort ?? "",
            "DEVSPACE_DEV_POD_FORWARD_PORT": developmentPodForwardPort ?? "",
            "DIDE_TEST_LIVE_PORTS": livePorts.map(String.init).joined(separator: ","),
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

    func runTwice(shell: ShellSpec, command: String, currentDirectory: URL) throws -> DideRunResult {
        let payloadFile = root.appendingPathComponent("payload-\(UUID().uuidString).json")
        let argsFile = root.appendingPathComponent("curl-args-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.path)
        process.currentDirectoryURL = currentDirectory
        process.arguments = ["-c", ". \"$SNIPPET\"; \"$0\"; \"$0\"", command]
        process.environment = [
            "HOME": root.path,
            "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "SNIPPET": snippetFile.path,
            "DIDE_TEST_PAYLOAD_FILE": payloadFile.path,
            "DIDE_TEST_CURL_ARGS_FILE": argsFile.path,
            "DIDE_TEST_BASE64_FAIL": "0",
            "DIDE_TEST_CURL_FAIL_POST": "0",
            "DEVSPACE_PROD_POD_FORWARD_PORT": "",
            "DEVSPACE_DEV_POD_FORWARD_PORT": "",
            "DIDE_TEST_LIVE_PORTS": [PodPortRouting.productionPort, PodPortRouting.developmentPort]
                .map(String.init).joined(separator: ","),
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        return DideRunResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            payload: try? String(contentsOf: payloadFile, encoding: .utf8),
            curlArguments: []
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
