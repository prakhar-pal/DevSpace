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
        XCTAssertTrue(decoded.contains("local target=\"${1:-.}\""))
        XCTAssertTrue(decoded.contains("cd -- \"$target\""))
        XCTAssertTrue(decoded.contains("pwd -P"))
        XCTAssertTrue(decoded.contains("path_b64"))
        XCTAssertTrue(decoded.contains("pod_id"))
        XCTAssertTrue(decoded.contains("wc-1"))
        XCTAssertTrue(decoded.contains("token"))
        XCTAssertTrue(decoded.contains("sekret-token"))
        XCTAssertTrue(decoded.contains("http://localhost:\(SSH.podForwardPort)/dide"))
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
}
