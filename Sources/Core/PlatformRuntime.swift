import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Linux Dispatch workers block most signals. A child must not inherit that
/// mask or SIGTERM cancellation (and terminal job control) cannot work.
/// Restore the calling thread's mask immediately after spawn.
func runDesktopProcess(_ process: Process) throws {
    #if os(Linux)
    var empty = sigset_t()
    var previous = sigset_t()
    sigemptyset(&empty)
    let result = pthread_sigmask(SIG_SETMASK, &empty, &previous)
    guard result == 0 else { throw DevpodError("could not reset child signal mask: \(result)") }
    defer { _ = pthread_sigmask(SIG_SETMASK, &previous, nil) }
    #endif
    try process.run()
}

func runDesktopSSHMaster(_ process: Process) throws {
    #if os(Linux)
    // OpenSSH closes inherited FDs >= 3. Foundation uses one as its lifetime
    // notification; early closure blocks its shared manager in waitpid until
    // the master exits, preventing readiness checks from being reaped.
    // A small supervisor retains that FD and forwards termination to an owned
    // session, including ProxyCommand/Match exec helpers. "$@" preserves argv
    // without shell interpolation. setsid is supplied by Ubuntu's util-linux.
    guard let executable = process.executableURL else { try runDesktopProcess(process); return }
    let arguments = process.arguments ?? []
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", """
        child=
        stopping=
        stop_child() {
            [ -z "$child" ] || { kill -TERM "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || :; }
        }
        trap 'stopping=1; stop_child' TERM INT HUP
        /usr/bin/setsid "$@" & child=$!
        [ -z "$stopping" ] || stop_child
        wait "$child"
        status=$?
        if [ -n "$stopping" ]; then
            while kill -0 "$child" 2>/dev/null; do
                wait "$child" 2>/dev/null
                [ "$?" -ne 127 ] || break
            done
            exit 143
        fi
        exit "$status"
        """, "devspace-ssh-master", executable.path] + arguments
    #endif
    try runDesktopProcess(process)
}

/// Explicit identity supplied by a frontend or launcher. Linux executables are
/// not app bundles, so selecting the development channel must never depend on
/// `Bundle.main` being populated.
public struct DevSpaceRuntimeIdentity: Equatable, Sendable {
    public enum Channel: String, Codable, Equatable, Sendable {
        case production
        case development

        public var applicationIdentifier: String {
            switch self {
            case .production: "com.prakharp.devspace"
            case .development: "com.prakharp.devspace.dev"
            }
        }

        fileprivate var linuxDirectoryName: String {
            switch self {
            case .production: "devspace"
            case .development: "devspace-dev"
            }
        }
    }

    public let channel: Channel

    public init(channel: Channel = .production) {
        self.channel = channel
    }

    /// The command-line backend and Linux frontend use this environment value.
    /// Invalid or absent values deliberately fail closed to production, matching
    /// the existing app's conservative default.
    public init(environment: [String: String]) {
        self.init(channel: environment["DEVSPACE_BUILD_CHANNEL"] == Channel.development.rawValue
            ? .development
            : .production)
    }
}

/// A platform selection that can be injected by tests and by the backend
/// launcher. The selected paths keep development and production instances
/// isolated while preserving the macOS locations used by existing installs.
public struct DevSpacePaths: Equatable, Sendable {
    public enum Platform: Equatable, Sendable {
        case macOS
        case linux
    }

    public let configDirectory: URL
    /// Remote hooks prefer production but can use development. Both listeners
    /// therefore authenticate with one per-user secret, as on macOS.
    public let notificationTokenDirectory: URL
    public let stateDirectory: URL
    public let runtimeDirectory: URL

    public init(
        platform: Platform,
        channel: DevSpaceRuntimeIdentity.Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        uid: UInt32 = getuid()
    ) {
        let home = environment["HOME"].map(URL.init(fileURLWithPath:))

        switch platform {
        case .macOS:
            let root = home ?? FileManager.default.homeDirectoryForCurrentUser
            configDirectory = root.appendingPathComponent("Library/Application Support/DevSpace")
            notificationTokenDirectory = configDirectory
            stateDirectory = root.appendingPathComponent(
                channel == .development ? "Library/Logs/DevSpaceDev" : "Library/Logs/DevSpace"
            )
            runtimeDirectory = URL(fileURLWithPath: "/tmp")
                .appendingPathComponent("devspace-ssh-\(uid)-\(channel == .development ? "dev" : "prod")")

        case .linux:
            // XDG paths must be absolute; empty/relative values are unset.
            func absolutePath(_ key: String) -> URL? {
                guard let value = environment[key], value.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: value)
            }
            let fallbackHome = absolutePath("HOME") ?? FileManager.default.homeDirectoryForCurrentUser
            let configRoot = absolutePath("XDG_CONFIG_HOME")
                ?? fallbackHome.appendingPathComponent(".config")
            let stateRoot = absolutePath("XDG_STATE_HOME")
                ?? fallbackHome.appendingPathComponent(".local/state")
            let xdgRuntime = absolutePath("XDG_RUNTIME_DIR")
            let runtimeRoot = xdgRuntime ?? URL(fileURLWithPath: "/tmp")
            let name = channel.linuxDirectoryName
            configDirectory = configRoot.appendingPathComponent(name)
            notificationTokenDirectory = configRoot.appendingPathComponent("devspace")
            stateDirectory = stateRoot.appendingPathComponent(name)
            runtimeDirectory = runtimeRoot.appendingPathComponent(
                xdgRuntime == nil ? "\(name)-\(uid)" : name
            )
        }
    }

    public static var current: DevSpacePaths {
        #if os(Linux)
        DevSpacePaths(
            platform: .linux,
            channel: DevSpaceRuntimeIdentity(environment: ProcessInfo.processInfo.environment).channel
        )
        #else
        DevSpacePaths(platform: .macOS, channel: .production)
        #endif
    }
}
