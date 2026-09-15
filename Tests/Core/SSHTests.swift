import XCTest
@testable import DevSpaceCore

// Mirrors pty.rs builds_ssh_args_for_devpod_alias + the action arg builders.
final class SSHTests: XCTestCase {
    func testBuildsSSHArgsForDevpodAlias() {
        let args = SSH.args(podID: "wc-1")
        XCTAssertTrue(args.contains("-tt"))
        XCTAssertTrue(args.contains { $0.hasPrefix("SetEnv=TERM=") })
        XCTAssertTrue(args.contains("-R"))
        XCTAssertTrue(args.contains("\(SSH.podForwardPort):localhost:\(SSH.listenerPort)"))
        XCTAssertEqual(args.last, "wc-1.devpod")
    }

    func testProductionSSHUsesOnlyProductionPortVariable() {
        let args = SSH.args(podID: "wc-1", bundleIdentifier: "com.prakharp.devspace")
        XCTAssertTrue(args.contains("SetEnv=DEVSPACE_PROD_POD_FORWARD_PORT=8765"))
        XCTAssertFalse(args.contains { $0.contains("DEVSPACE_DEV_POD_FORWARD_PORT") })
        XCTAssertFalse(args.contains { $0.contains("DEVSPACE_POD_FORWARD_PORT=") })
    }

    func testDevelopmentSSHUsesOnlyDevelopmentPortVariable() {
        let args = SSH.args(podID: "wc-1", bundleIdentifier: "com.prakharp.devspace.dev")
        XCTAssertTrue(args.contains("SetEnv=DEVSPACE_DEV_POD_FORWARD_PORT=8766"))
        XCTAssertFalse(args.contains { $0.contains("DEVSPACE_PROD_POD_FORWARD_PORT") })
        XCTAssertFalse(args.contains { $0.contains("DEVSPACE_POD_FORWARD_PORT=") })
    }

    func testBundleSpecificSSHUsesMatchingReverseTunnelPair() {
        XCTAssertTrue(
            SSH.args(podID: "wc-1", bundleIdentifier: "com.prakharp.devspace")
                .contains("8765:localhost:17865")
        )
        XCTAssertTrue(
            SSH.args(podID: "wc-1", bundleIdentifier: "com.prakharp.devspace.dev")
                .contains("8766:localhost:17866")
        )
    }

    func testPorts() {
        XCTAssertEqual(SSH.listenerPort, 17865)
        XCTAssertEqual(SSH.podForwardPort, 8765)
    }

    func testDevBundleUsesSeparateReverseTunnelPorts() {
        XCTAssertEqual(
            SSH.ports(bundleIdentifier: "com.prakharp.devspace.dev"),
            SSH.Ports(listenerPort: 17866, podForwardPort: 8766)
        )
        XCTAssertEqual(
            SSH.ports(bundleIdentifier: "com.prakharp.devspace"),
            SSH.Ports(listenerPort: 17865, podForwardPort: 8765)
        )
    }

    func testSharedPodFallbackPreservesProductionPort() {
        XCTAssertEqual(SSH.sharedPodForwardFallback, 8765)
    }

    func testSecondaryTerminalSkipsReverseTunnel() {
        let args = SSH.args(podID: "wc-1", tunnel: false)
        XCTAssertFalse(args.contains("-R"))
        XCTAssertEqual(args.last, "wc-1.devpod")
        // The default (primary) still carries the tunnel.
        XCTAssertTrue(SSH.args(podID: "wc-1").contains("-R"))
    }

    func testBuildsArgsWithDevpodServiceForwardingDisabled() {
        let proxy = #"\"/Users/x/.local/bin/devpod\" ssh --stdio --context default --user node wc-1 --workdir \"/workspace\""#
        let args = SSH.args(podID: "wc-1", proxyCommand: proxy)

        XCTAssertTrue(args.contains("-o"))
        XCTAssertTrue(args.contains("ProxyCommand=\(proxy) --start-services=false"))
        XCTAssertTrue(args.contains("-R"))
        XCTAssertEqual(args.last, "wc-1.devpod")
    }

    func testParsesOnlySimpleDevpodStdioProxyCommand() {
        let config = #"proxycommand \"/Users/x/.local/bin/devpod\" ssh --stdio --context default wc-1"#
        XCTAssertEqual(
            SSH.devpodProxyCommand(effectiveConfig: config),
            #"\"/Users/x/.local/bin/devpod\" ssh --stdio --context default wc-1"#
        )
    }

    func testAcceptsSingleQuotedDevpodExecutable() {
        let config = "proxycommand '/Users/x/.local/bin/devpod' ssh --stdio wc-1"
        XCTAssertEqual(
            SSH.devpodProxyCommand(effectiveConfig: config),
            "'/Users/x/.local/bin/devpod' ssh --stdio wc-1"
        )
    }

    func testRejectsNonDevpodAndShellComposedProxyCommands() {
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand none"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand ssh jump.example"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand devpod ssh --stdio wc-1 ; echo unsafe"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand devpod ssh --stdio wc-1 $(echo unsafe)"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand devpod ssh --stdio wc-1 `echo unsafe`"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand devpod ssh --stdio wc-1 ${UNSAFE}"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand devpod ssh --stdio wc-1 # unsafe"))
    }

    func testRejectsUnbracedParameterAndPathnameExpansionInProxyCommand() {
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand /tmp/$DEVPOD_DIR/devpod ssh --stdio wc-1"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand $HOME/bin/devpod ssh --stdio wc-1"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand /tmp/*/devpod ssh --stdio wc-1"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand /tmp/?/devpod ssh --stdio wc-1"))
        XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand /tmp/[a-z]/devpod ssh --stdio wc-1"))
    }

    func testSecondaryTerminalRetainsProxyOverrideWithoutReverseTunnel() {
        let args = SSH.args(podID: "wc-1", tunnel: false, proxyCommand: "devpod ssh --stdio wc-1")
        XCTAssertTrue(args.contains("ProxyCommand=devpod ssh --stdio wc-1 --start-services=false"))
        XCTAssertFalse(args.contains("-R"))
    }

    func testMasterOwnsReverseTunnelAndControlSocket() {
        let args = SSH.masterArgs(
            podID: "wc-1",
            proxyCommand: "devpod ssh --stdio wc-1",
            controlPath: "/tmp/devspace/socket",
            bundleIdentifier: "com.prakharp.devspace"
        )

        XCTAssertTrue(args.contains("-N"))
        XCTAssertTrue(args.contains("ControlMaster=yes"))
        XCTAssertTrue(args.contains("ControlPersist=no"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("ControlPath=/tmp/devspace/socket"))
        XCTAssertTrue(args.contains("8765:localhost:17865"))
        XCTAssertTrue(args.contains("-R"))
    }

    func testClientUsesExistingControlSocketWithoutReverseTunnel() {
        let args = SSH.clientArgs(
            podID: "wc-1",
            proxyCommand: "devpod ssh --stdio wc-1",
            controlPath: "/tmp/devspace/socket"
        )

        XCTAssertTrue(args.contains("-tt"))
        XCTAssertTrue(args.contains("ControlMaster=no"))
        XCTAssertTrue(args.contains("ControlPersist=no"))
        XCTAssertTrue(args.contains("ControlPath=/tmp/devspace/socket"))
        XCTAssertFalse(args.contains("-R"))
    }
}

// The `zed ssh://…` remote-open path: workdir parsing from the devpod-managed
// ~/.ssh/config host alias, and the URL handed to the zed CLI.
final class ZedRemoteTests: XCTestCase {
    private let config = """
    # DevPod Start wc-1.devpod
    Host wc-1.devpod
      ForwardAgent yes
      ProxyCommand "/Users/x/.local/bin/devpod" ssh --stdio --context default --user node wc-1 --workdir "/workspace"
      User node
    # DevPod End wc-1.devpod
    Host wc-2.devpod
      ProxyCommand "/Users/x/.local/bin/devpod" ssh --stdio --user node wc-2 --workdir /workspaces/webclients
      User node
    Host other-host
      ProxyCommand something --workdir "/decoy"
    """

    func testParsesQuotedWorkdirFromHostBlock() {
        XCTAssertEqual(SSH.parseWorkdir(sshConfig: config, podID: "wc-1"), "/workspace")
    }

    func testParsesUnquotedWorkdir() {
        XCTAssertEqual(SSH.parseWorkdir(sshConfig: config, podID: "wc-2"), "/workspaces/webclients")
    }

    func testIgnoresOtherHostBlocks() {
        XCTAssertNil(SSH.parseWorkdir(sshConfig: config, podID: "wc-9"))
    }

    func testMissingWorkdirIsNil() {
        let bare = "Host wc-3.devpod\n  ProxyCommand devpod ssh --stdio wc-3\n"
        XCTAssertNil(SSH.parseWorkdir(sshConfig: bare, podID: "wc-3"))
    }

    func testZedRemoteURL() {
        XCTAssertEqual(
            SSH.zedRemoteURL(podID: "wc-1", workdir: "/workspace"),
            "ssh://wc-1.devpod/workspace"
        )
        // A relative workdir is normalized to an absolute path component.
        XCTAssertEqual(
            SSH.zedRemoteURL(podID: "wc-1", workdir: "workspace"),
            "ssh://wc-1.devpod/workspace"
        )
        // URL-reserved characters in the workdir are percent-encoded.
        XCTAssertEqual(
            SSH.zedRemoteURL(podID: "wc-1", workdir: "/my project"),
            "ssh://wc-1.devpod/my%20project"
        )
    }

    func testZedWorkdirPrefersReportedTerminalDirectory() {
        XCTAssertEqual(
            SSH.zedWorkdir(
                currentDirectory: "/workspaces/webclients/packages/app",
                fallback: "/workspace"
            ),
            "/workspaces/webclients/packages/app"
        )
    }

    func testZedWorkdirFallsBackUntilTerminalReportsDirectory() {
        XCTAssertEqual(SSH.zedWorkdir(currentDirectory: nil, fallback: "/workspace"), "/workspace")
        XCTAssertEqual(SSH.zedWorkdir(currentDirectory: "", fallback: "/workspace"), "/workspace")
    }

    // Real process-table lines captured while Zed had wc-2 open remotely.
    private let zedMaster = "ssh -N -o ControlPersist=no -o ControlMaster=yes "
        + "-o ControlPath=/var/folders/30/T/zed-ssh-sessionU9kVda/ssh.sock wc-2.devpod"
    private let zedProxy = "ssh -o ControlMaster=no "
        + "-o ControlPath=/var/folders/30/T/zed-ssh-sessionU9kVda/ssh.sock wc-2.devpod "
        + "-T cd; env .zed_server/zed-remote-server-stable-1.9.0 proxy --identifier workspace-66"
    private let devspaceSSH = "ssh -tt -o StrictHostKeyChecking=no -R 8765:localhost:17865 wc-2.devpod"

    func testZedSessionActiveMatchesZedControlMasterForPod() {
        let ps = [devspaceSSH, zedMaster, zedProxy].joined(separator: "\n")
        XCTAssertTrue(SSH.zedSessionActive(psOutput: ps, podID: "wc-2"))
    }

    func testZedSessionActiveIgnoresOtherPodsAndPrefixIDs() {
        let ps = [zedMaster, zedProxy].joined(separator: "\n")
        XCTAssertFalse(SSH.zedSessionActive(psOutput: ps, podID: "wc-1"))
        // "wc-2" session must not count for pod "wc-2a" (and vice versa).
        XCTAssertFalse(SSH.zedSessionActive(psOutput: ps, podID: "wc-2a"))
    }

    func testZedSessionActiveIgnoresDevspaceOwnSSH() {
        // DevSpace's own terminal ssh mentions the alias but is not a Zed session.
        XCTAssertFalse(SSH.zedSessionActive(psOutput: devspaceSSH, podID: "wc-2"))
    }
}

// The `scp` destination the image-paste feature copies a local file to,
// over the same devpod alias `zedRemoteURL`/`args` rely on.
final class ScpDestinationTests: XCTestCase {
    func testBuildsDevpodAliasDestination() {
        XCTAssertEqual(
            SSH.scpDestination(podID: "wc-1", remotePath: "/tmp/devspace-paste-ABC.png"),
            "wc-1.devpod:/tmp/devspace-paste-ABC.png"
        )
    }

    func testDistinctPodIDsWithSharedPrefixDontCollide() {
        // wc-2 and wc-2a must resolve to different destinations, not aliasing.
        XCTAssertEqual(
            SSH.scpDestination(podID: "wc-2a", remotePath: "/tmp/x.png"),
            "wc-2a.devpod:/tmp/x.png"
        )
        XCTAssertNotEqual(
            SSH.scpDestination(podID: "wc-2a", remotePath: "/tmp/x.png"),
            SSH.scpDestination(podID: "wc-2", remotePath: "/tmp/x.png")
        )
    }
}

final class ActionArgsTests: XCTestCase {
    func testUpArgs() {
        XCTAssertEqual(Devpod.upArgs("wc-1"), ["up", "--ide", "none", "--", "wc-1"])
    }

    func testStopArgs() {
        XCTAssertEqual(Devpod.stopArgs("wc-1"), ["stop", "--", "wc-1"])
    }

    func testIdeArgs() {
        XCTAssertEqual(Devpod.ideArgs("wc-1", ide: "zed"), ["up", "--ide", "zed", "--", "wc-1"])
    }

    func testValidateIde() {
        XCTAssertNoThrow(try Devpod.validateIde("zed"))
        XCTAssertNoThrow(try Devpod.validateIde("vs-code"))
        XCTAssertThrowsError(try Devpod.validateIde("zed; rm -rf"))
        XCTAssertThrowsError(try Devpod.validateIde(""))
    }
}
