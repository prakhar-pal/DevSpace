# Linux application

The Linux frontend is a DevSpace-owned Swift/GTK4 application. It embeds the
system VTE widget for terminal rendering and input; it does not reuse or imitate
Ghostty's GTK application. The macOS app continues to use SwiftUI and
libghostty.

GTK4 and VTE are imported by SwiftPM as system libraries (`gtk4` and
`vte-2.91-gtk4`). DevSpace UI, workspace presentation, protocol handling, and
process lifecycle remain Swift. `DevSpaceLinuxBackend` owns DevPod, SSH masters,
hooks, notification routing, image upload, and the versioned private protocol.
VTE owns the terminal child process and PTY; terminal bytes never go through the
backend pipe.

## Dependencies

On Ubuntu, install the C headers and build tools:

```sh
sudo apt-get install -y build-essential dpkg-dev pkg-config libgtk-4-dev \
  libvte-2.91-gtk4-dev
```

The running app also needs GTK4, VTE GTK4, OpenSSH, `setsid` (`util-linux`), and
the user-installed `devpod` executable. GTK/VTE remain system dependencies and
are not copied into the bundle. Swift runtime libraries are bundled.

## Build and run

From the repository root:

```sh
make linux-build-dev
make linux-bundle-dev
make linux-run
```

The build products are `build/linux-dev/bin/DevSpaceLinuxApp` and
`DevSpaceLinuxBackend`. The relocatable development bundle is
`build/linux-dev-bundle`; it includes the channel-named app/backend, Swift
runtime libraries, desktop metadata, icon, and `bin/devspace-dev` launcher.
The launcher establishes the development identity and repaired executable
search path, then starts DevSpace without terminating another instance.

`make linux-test-protocol` runs the Swift backend-client protocol tests through
the installed compiler. `make linux-test-gtk` exercises the actual GTK/VTE
widgets under a private Xvfb display. `make linux-test-core` uses SwiftPM's
Core XCTest target; `make linux-test` runs the Python integration and packaging
suite after building the backend.

To build a production Ubuntu package, provide the project's Debian copyright
manifest and maintainer identity:

```sh
make linux-package \
  LINUX_PACKAGE_COPYRIGHT=/path/to/debian/copyright \
  LINUX_PACKAGE_MAINTAINER="Name <email>"
```

The `.deb` bundles the Swift runtime and installs DevSpace under `/usr/lib`,
with the launcher and desktop metadata in standard system paths. GTK4, VTE,
OpenSSH, and util-linux remain package dependencies; DevPod is user-installed.
`dpkg-shlibdeps` derives versioned system-library requirements from the app and
all bundled Swift libraries. A package built on Ubuntu 26.04 requires that
host ABI; Ubuntu 24.04 compatibility is not claimed. The copyright manifest
must cover the project and bundled third-party runtime code.
This target builds release artifacts and requires confirmation before use. A
complete Debian copyright manifest is not yet present in the repository.
DevSpace-owned source is GPL-3.0-or-later; bundles carry the project GPL text
and the selected Swift toolchain license, but embedded ICU/artwork attribution
still needs separate coverage before distribution.

On the current Ubuntu 26.04 development host, use the globally installed
Swift.org 6.4.1 toolchain (`swift`/`swiftc` on `PATH`). Its SwiftPM runner is
host-compatible; no compiler is stored in the repository. Confirm the selected
version with `swift --version`. Ubuntu 24.04 acceptance is deferred by user
direction.

## Safety and test scope

GTK tests use controlled backend peers and temporary local shells on Xvfb;
they do not access a real workspace or replace the desktop clipboard. Tests
that exercise the actual desktop, notification banner, IME, or a remote shell
must be treated as separate manual acceptance. An approved `wc-1` terminal may
be used only for temporary shell checks; do not start, stop, delete, or change
workspace files as part of frontend tests.

The GTK layer does not own workspace lifecycle, hooks, the notification token,
or uploads. It maps validated generation-bound terminal effects to VTE panes,
and rejects stale pane callbacks. Closing a terminal pane leaves its workspace
running. Development and production use distinct application IDs and per-channel
layout/state while retaining the existing backend behavior.
