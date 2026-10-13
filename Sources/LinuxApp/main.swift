import Foundation
import Glibc
import CGTK

@_cdecl("devspace_linux_activate")
private func devspaceLinuxActivate(_ application: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    let controller = Unmanaged<LinuxApplicationController>.fromOpaque(data).takeUnretainedValue()
    do {
        try controller.start()
    } catch {
        fputs("DevSpaceLinuxApp: \(error)\n", stderr)
        if let application {
            g_application_quit(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self))
        }
    }
}

guard let channel = ProcessInfo.processInfo.environment["DEVSPACE_BUILD_CHANNEL"],
      let applicationIdentifier = LinuxApplicationChannel.applicationIdentifier(channel) else {
    fputs("DevSpaceLinuxApp: DEVSPACE_BUILD_CHANNEL must be development or production\n", stderr)
    exit(EXIT_FAILURE)
}

let application = gtk_application_new(applicationIdentifier, GApplicationFlags(rawValue: 0))!
let backendExecutable = LinuxApplicationChannel.backendExecutableURL(
    URL(fileURLWithPath: CommandLine.arguments[0]),
    environment: ProcessInfo.processInfo.environment
)
let controller = LinuxApplicationController(
    application: application, channel: channel, backendExecutableURL: backendExecutable
)
let activateCallback = unsafeBitCast(
    devspaceLinuxActivate as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
    to: GCallback.self
)
_ = g_signal_connect_data(
    application, "activate", activateCallback, Unmanaged.passUnretained(controller).toOpaque(),
    nil, GConnectFlags(rawValue: 0)
)
_ = g_application_run(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self), 0, nil)
