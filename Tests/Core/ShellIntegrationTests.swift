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
        let script = ShellIntegration.injectScript()
        // Old marker blocks are deleted before appending, so snippet updates
        // self-upgrade instead of staying pinned to the first-injected version.
        XCTAssertTrue(script.contains("sed -i"))
        XCTAssertTrue(script.contains(".bashrc"))
        XCTAssertTrue(script.contains(".zshrc"))
        XCTAssertTrue(script.contains("base64 -d >>")) // append, never overwrite
    }

    func testInjectScriptPayloadRoundTrips() throws {
        // The base64 payload must decode back to the exact snippet.
        let script = ShellIntegration.injectScript()
        let b64 = try XCTUnwrap(
            script.split(separator: " ").first { $0.hasPrefix("IyA") || $0.hasPrefix("CiMg") }
        )
        let decoded = String(decoding: try XCTUnwrap(Data(base64Encoded: String(b64))), as: UTF8.self)
        XCTAssertEqual(decoded, "\n" + ShellIntegration.snippet + "\n")
    }

    func testInjectRejectsInvalidPodID() {
        struct NoRun: CommandRunning {
            func run(_ args: [String]) throws -> String {
                XCTFail("must not run for an invalid id")
                return ""
            }
        }
        XCTAssertThrowsError(try ShellIntegration.inject(NoRun(), podID: "-rf"))
    }

    func testInjectRunsDevpodSSHForValidID() throws {
        final class Recorder: CommandRunning {
            var calls: [[String]] = []
            func run(_ args: [String]) throws -> String {
                calls.append(args)
                return ""
            }
        }
        let r = Recorder()
        try ShellIntegration.inject(r, podID: "wc-1")
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls[0].first, "ssh")
        XCTAssertEqual(r.calls[0].last, "wc-1")
        XCTAssertTrue(r.calls[0].contains("--")) // id can't be parsed as a flag
    }
}
