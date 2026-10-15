#!/usr/bin/env python3
"""Assemble a relocatable Linux bundle without altering its build inputs."""

import argparse
import json
from pathlib import Path
import shutil
import struct
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def icon_png(path):
    """Extract an existing PNG representation; do not redraw the app's icon."""
    data = path.read_bytes()
    if data[:4] != b"icns":
        raise ValueError(f"not an ICNS icon: {path}")
    images = []
    offset = 8
    while offset + 8 <= len(data):
        size = struct.unpack_from(">I", data, offset + 4)[0]
        if size < 8 or offset + size > len(data):
            raise ValueError(f"invalid icon entry: {path}")
        payload = data[offset + 8:offset + size]
        if payload.startswith(b"\x89PNG\r\n\x1a\n") and len(payload) >= 24:
            width = struct.unpack_from(">I", payload, 16)[0]
            images.append((width, payload))
        offset += size
    if not images:
        raise ValueError(f"icon has no PNG representation: {path}")
    return min(images, key=lambda item: abs(item[0] - 512))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frontend", required=True, type=Path)
    parser.add_argument("--backend", required=True, type=Path)
    parser.add_argument("--swift-runtime", required=True, type=Path)
    parser.add_argument("--swift-license", type=Path,
                        help="LICENSE.txt from the selected Swift toolchain (default: its usr/share/swift)")
    parser.add_argument("--icu-license", type=Path,
                        help="complete notice for the ICU version embedded in the selected Swift runtime")
    parser.add_argument("--channel", choices=("development", "production"), required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--replace", action="store_true",
                        help="refresh only a bundle generated for the same channel")
    args = parser.parse_args()
    output = args.output.absolute()
    marker = {"producer": "devspace-linux-bundle", "version": 1, "channel": args.channel}
    replacing = output.exists() or output.is_symlink()
    if replacing:
        if not args.replace:
            parser.exit(1, f"Output already exists: {output}; existing work was left intact.\n")
        marker_path = output / ".devspace-bundle.json"
        try:
            matching = (not output.is_symlink() and output.is_dir()
                        and not marker_path.is_symlink()
                        and json.loads(marker_path.read_text()) == marker)
        except (OSError, ValueError):
            matching = False
        if not matching:
            parser.exit(1, f"Refusing to replace an unrecognized or different-channel bundle: {output}\n")
    if not (args.swift_runtime / "libswiftCore.so").is_file():
        parser.exit(1, "Swift runtime directory must contain libswiftCore.so\n")
    swift_license = args.swift_license or args.swift_runtime.absolute().parents[2] / "share/swift/LICENSE.txt"
    if not swift_license.is_file() or swift_license.stat().st_size == 0:
        parser.exit(1, f"Swift toolchain license notice is missing: {swift_license}\n")
    if (args.swift_runtime / "lib_FoundationICU.so").is_file():
        if not args.icu_license or not args.icu_license.is_file() or args.icu_license.stat().st_size == 0:
            parser.exit(1, "ICU runtime requires a nonempty --icu-license notice matching its version\n")
    development = args.channel == "development"
    name = "DevSpaceDev" if development else "DevSpace"
    command = "devspace-dev" if development else "devspace"
    identity = "com.prakharp.devspace.dev" if development else "com.prakharp.devspace"
    width, icon = icon_png(ROOT / "Resources" / f"{name}.icns")
    app = args.frontend / "bin/DevSpaceLinuxApp"
    if not app.is_file():
        parser.exit(1, f"Swift Linux application was not built: {app}\n")
    if not args.backend.is_file():
        parser.exit(1, f"Swift Linux backend was not built: {args.backend}\n")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".devspace-bundle-", dir=output.parent) as temporary:
        bundle = Path(temporary) / "bundle"
        (bundle / "bin").mkdir(parents=True)
        (bundle / "lib").mkdir()
        shutil.copy2(app, bundle / "bin" / name)
        shutil.copy2(args.backend, bundle / "bin" / f"{name}Backend")
        (bundle / "bin" / f"{name}Backend").chmod(0o755)
        for runtime in args.swift_runtime.glob("*.so*"):
            if runtime.is_file():
                shutil.copy2(runtime, bundle / "lib" / runtime.name)
        documentation = bundle / "share/doc/devspace"
        documentation.mkdir(parents=True)
        shutil.copyfile(ROOT / "LICENSE", documentation / "LICENSE")
        shutil.copyfile(swift_license, documentation / "swift-runtime-LICENSE.txt")
        if args.icu_license:
            shutil.copyfile(args.icu_license, documentation / "icu-LICENSE.txt")
        (documentation / "licensing.txt").write_text(
            "DevSpace-owned source code and custom app icons: GPL-3.0-or-later. See LICENSE.\n"
            "Third-party components retain their own licenses. The Swift toolchain\n"
            "license is provided separately; it is not a complete third-party inventory.\n"
            "Supplied ICU notices are preserved separately in icu-LICENSE.txt.\n"
            "The Debian package copyright manifest records the binary inventory.\n"
        )
        launcher = bundle / "bin" / command
        launcher.write_text(f'''#!/bin/sh
set -eu
devspace_launcher=$(readlink -f -- "$0")
devspace_prefix=$(CDPATH= cd -- "$(dirname -- "$devspace_launcher")/.." && pwd -P)
export DEVSPACE_BUILD_CHANNEL={args.channel}
export DEVSPACE_BACKEND="$devspace_prefix/bin/{name}Backend"
export LD_LIBRARY_PATH="$devspace_prefix/lib${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}"
export XDG_DATA_DIRS="$devspace_prefix/share:${{XDG_DATA_DIRS:-/usr/local/share:/usr/share}}"
export PATH="${{PATH:-/usr/local/bin:/usr/bin:/bin}}${{HOME:+:$HOME/.local/bin}}:/usr/local/bin"
if devspace_path=$("$DEVSPACE_BACKEND" --print-path 2>/dev/null); then
    export PATH="$devspace_path"
fi
exec "$devspace_prefix/bin/{name}" "$@"
''')
        launcher.chmod(0o755)
        desktop = bundle / "share/applications" / f"{identity}.desktop"
        desktop.parent.mkdir(parents=True)
        desktop.write_text(f"[Desktop Entry]\nType=Application\nName={name}\nExec={command}\n"
                           f"Icon={identity}\nTerminal=false\nCategories=Development;\nStartupWMClass={identity}\n")
        icon_path = bundle / "share/icons/hicolor" / f"{width}x{width}/apps/{identity}.png"
        icon_path.parent.mkdir(parents=True)
        icon_path.write_bytes(icon)
        (bundle / ".devspace-bundle.json").write_text(json.dumps(marker) + "\n")
        # Keep the recovery copy outside staging cleanup if rollback itself fails.
        recovery = Path(tempfile.mkdtemp(prefix=".devspace-previous-", dir=output.parent)) if replacing else None
        previous = recovery / "previous" if recovery else None
        try:
            if replacing:
                output.rename(previous)
            bundle.rename(output)
        except BaseException:
            if previous and previous.exists() and not output.exists():
                try:
                    previous.rename(output)
                except BaseException as error:
                    raise RuntimeError(f"Bundle rollback failed; previous bundle retained at {previous}") from error
            if recovery:
                shutil.rmtree(recovery)
            raise
        if recovery:
            shutil.rmtree(recovery)
    print(output)


if __name__ == "__main__":
    main()
