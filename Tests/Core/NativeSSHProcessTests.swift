import XCTest
#if os(Linux)
import Glibc
#endif
@testable import DevSpaceCore

#if os(Linux)
final class NativeSSHProcessTests: XCTestCase {
    func testNaturalSSHExitCleansUpMatchHelpersHoldingStderrOpen() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/native-ssh-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let pidFile = directory.appendingPathComponent("helper.pid")
        let helper = directory.appendingPathComponent("helper.sh")
        let config = directory.appendingPathComponent("ssh-config")
        let pidPath = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/sh\n/bin/sleep 30 &\nprintf '%s' \"$!\" > \(pidPath)\nprintf native-helper-started >&2\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try "Match exec \"\(helper.path)\"\n".write(to: config, atomically: true, encoding: .utf8)
        var ownedPID: Int32?
        var identity: String?
        defer {
            if let pid = ownedPID, let identity,
               SSHTransportControlLease.processIdentity(pid) == identity { _ = kill(pid, SIGTERM) }
            try? FileManager.default.removeItem(at: directory)
        }
        let exited = expectation(description: "SSH exit closes inherited helper pipes")
        let process = try FoundationSSHTransportProcess(arguments: ["-F", config.path, "-G", "localhost"]) { status in
            XCTAssertEqual(status, 0)
            exited.fulfill()
        }
        defer { process.terminate() }
        let diagnostic = expectation(for: NSPredicate { _, _ in
            process.stderrTail.contains("native-helper-started")
        }, evaluatedWith: nil)
        wait(for: [diagnostic], timeout: 5)
        ownedPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))
        if let pid = ownedPID { identity = SSHTransportControlLease.processIdentity(pid) }
        wait(for: [exited], timeout: 5)
    }

    func testTerminationDrainsPipesAndStopsTheOwnedLocalProxy() throws {
        let exited = expectation(description: "owned local SSH process exits after termination")
        let process = try FoundationSSHTransportProcess(arguments: [
            "-F", "/dev/null", "-o", "BatchMode=yes",
            "-o", "ProxyCommand=/bin/sh -c 'printf devspace-native-cancel >&2; sleep 30'",
            "localhost",
        ]) { status in
            XCTAssertEqual(status, 143)
            exited.fulfill()
        }
        defer { process.terminate() }
        let diagnostic = expectation(for: NSPredicate { _, _ in
            process.stderrTail.contains("devspace-native-cancel")
        }, evaluatedWith: nil)
        wait(for: [diagnostic], timeout: 5)
        process.terminate()
        wait(for: [exited], timeout: 5)
        XCTAssertTrue(process.stderrTail.contains("devspace-native-cancel"))
    }

    func testRapidLocalSSHExitsDeliverStderrBeforeCompletion() throws {
        for batch in 0..<8 {
            var processes: [FoundationSSHTransportProcess] = []
            var completions: [XCTestExpectation] = []
            for index in 0..<16 {
                let exited = expectation(description: "local SSH version command \(batch):\(index) exited")
                processes.append(try FoundationSSHTransportProcess(arguments: ["-V"]) { status in
                    XCTAssertEqual(status, 0)
                    exited.fulfill()
                })
                completions.append(exited)
            }
            wait(for: completions, timeout: 10)
            for process in processes {
                XCTAssertTrue(process.stderrTail.contains("OpenSSH"),
                              "completion discarded the local SSH diagnostic in batch \(batch)")
                process.terminate()
            }
        }
    }
}
#endif
