#!/usr/bin/env python3
"""Build a relocatable Ubuntu package from a production Linux bundle."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "devspace"
IDENTITY = "com.prakharp.devspace"
COPYRIGHT_FORMAT = "https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
DEPENDENCIES = ("libgtk-4-1", "libvte-2.91-gtk4-0", "openssh-client", "util-linux")


def dependencies(prefix, work):
    """Ask Debian's symbol metadata for every binary and bundled runtime library."""
    elf_files = []
    for path in sorted((*prefix.joinpath("bin").iterdir(), *prefix.joinpath("lib").iterdir())):
        if path.is_file():
            with path.open("rb") as file:
                if file.read(4) == b"\x7fELF":
                    elf_files.append(path)
    derived = []
    if elf_files:
        (work / "debian/control").write_text(
            f"Source: {PACKAGE}\n\nPackage: {PACKAGE}\nArchitecture: any\n"
            "Description: DevPod workspace manager\n"
        )
        output = subprocess.check_output([
            "dpkg-shlibdeps", f"--package={PACKAGE}", "-O", f"-l{prefix / 'lib'}",
            f"-S{work / 'debian' / PACKAGE}", *map(str, elf_files),
        ], cwd=work, text=True)
        for line in output.splitlines():
            if line.startswith("shlibs:Depends="):
                derived.extend(line.removeprefix("shlibs:Depends=").split(", "))
    names = {dependency.split()[0] for dependency in derived}
    return ", ".join(derived + [name for name in DEPENDENCIES if name not in names])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True,
                        help="production bundle made by assemble-linux.py")
    parser.add_argument("--copyright-file", type=Path, required=True,
                        help="project Debian copyright manifest")
    parser.add_argument("--swift-license", type=Path, required=True,
                        help="LICENSE.txt from the Swift toolchain supplying bundled runtime libraries")
    parser.add_argument("--maintainer", required=True,
                        help="Debian maintainer field, in 'Name <email>' form")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    bundle = args.bundle.absolute()
    output = args.output.absolute()
    try:
        marker = json.loads((bundle / ".devspace-bundle.json").read_text())
    except (OSError, ValueError) as error:
        parser.error(f"not a generated DevSpace bundle: {error}")
    if marker != {"producer": "devspace-linux-bundle", "version": 1, "channel": "production"}:
        parser.error("only a DevSpace production bundle can be packaged")
    if not re.fullmatch(r"[^<>\n]+ <[^<>\s@]+@[^<>\s@]+>", args.maintainer.strip()):
        parser.error("--maintainer must have the form 'Name <email>'")
    for file in (args.copyright_file, args.swift_license):
        if not file.is_file() or file.stat().st_size == 0:
            parser.error(f"required nonempty license notice is missing: {file}")
    icu_notice = bundle / "share/doc/devspace/icu-LICENSE.txt"
    if (bundle / "lib/lib_FoundationICU.so").is_file():
        if not icu_notice.is_file() or icu_notice.stat().st_size == 0:
            parser.error("ICU runtime license notice is missing from the bundle")
    try:
        copyright_text = args.copyright_file.read_text()
    except (OSError, UnicodeError) as error:
        parser.error(f"could not read Debian copyright manifest: {error}")
    copyright_lines = copyright_text.splitlines()
    if f"Format: {COPYRIGHT_FORMAT}" not in copyright_lines:
        parser.error("--copyright-file must be a Debian copyright-format 1.0 manifest")
    if not all(any(line.startswith(field) for line in copyright_lines)
               for field in ("Files:", "Copyright:", "License:")):
        parser.error("--copyright-file must include Files, Copyright, and License fields")
    required = (
        bundle / "bin/devspace", bundle / "bin/DevSpace", bundle / "bin/DevSpaceBackend",
        bundle / "share/applications" / f"{IDENTITY}.desktop",
    )
    if any(not path.is_file() for path in required):
        parser.error("production bundle is missing its launcher, executables, or desktop entry")
    if output.exists() or output.is_symlink():
        parser.error(f"output already exists; existing file was left intact: {output}")

    version = plistlib.loads((ROOT / "Info.plist").read_bytes()).get("CFBundleShortVersionString")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", version):
        parser.error("Info.plist has no valid three-part CFBundleShortVersionString")
    try:
        architecture = subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        parser.error(f"could not determine Debian package architecture: {error}")

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".devspace-deb-", dir=output.parent) as temporary:
        work = Path(temporary)
        root = work / "debian" / PACKAGE
        prefix = root / "usr/lib/devspace"
        shutil.copytree(bundle, prefix)

        launcher = root / "usr/bin/devspace"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to("../lib/devspace/bin/devspace")

        source_desktop = bundle / "share/applications" / f"{IDENTITY}.desktop"
        desktop_text = source_desktop.read_text()
        if desktop_text.count("Exec=devspace\n") != 1:
            parser.error("production desktop entry must contain exactly one Exec=devspace line")
        desktop = root / "usr/share/applications/devspace.desktop"
        desktop.parent.mkdir(parents=True)
        desktop.write_text(desktop_text.replace("Exec=devspace\n", "Exec=/usr/bin/devspace\n"))

        icon_sources = list((bundle / "share/icons/hicolor").glob(f"*/apps/{IDENTITY}.png"))
        if not icon_sources:
            parser.error("production bundle has no application icon")
        for source in icon_sources:
            destination = root / "usr/share/icons/hicolor" / source.relative_to(bundle / "share/icons/hicolor")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

        documentation = root / "usr/share/doc/devspace"
        documentation.mkdir(parents=True)
        shutil.copyfile(args.copyright_file, documentation / "copyright")
        shutil.copyfile(args.swift_license, documentation / "swift-runtime-LICENSE.txt")
        for name in ("LICENSE", "licensing.txt", "icu-LICENSE.txt"):
            notice = bundle / "share/doc/devspace" / name
            if notice.is_file():
                shutil.copyfile(notice, documentation / name)

        control = root / "DEBIAN/control"
        control.parent.mkdir()
        control.write_text(
            f"Package: {PACKAGE}\nVersion: {version}\nSection: devel\nPriority: optional\n"
            f"Architecture: {architecture}\nMaintainer: {args.maintainer.strip()}\n"
            f"Depends: {dependencies(prefix, work)}\nDescription: DevPod workspace manager\n"
            " Native GTK application with an embedded VTE terminal.\n"
        )

        staged_package = work / output.name
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(root), str(staged_package)],
                       check=True)
        os.link(staged_package, output)

    print(output)


if __name__ == "__main__":
    main()
