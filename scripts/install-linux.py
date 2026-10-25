#!/usr/bin/env python3
"""Install a production Linux bundle without replacing a running app."""

import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile


MARKER = {"producer": "devspace-linux-bundle", "version": 1, "channel": "production"}
IDENTITY = "com.prakharp.devspace"


def production_bundle(path):
    try:
        return (not path.is_symlink() and path.is_dir()
                and not (path / ".devspace-bundle.json").is_symlink()
                and json.loads((path / ".devspace-bundle.json").read_text()) == MARKER)
    except (OSError, ValueError):
        return False


def refuse_running(destination):
    binaries = {(stat.st_dev, stat.st_ino) for name in ["DevSpace", "DevSpaceBackend"]
                if (binary := destination / "bin" / name).exists()
                for stat in [binary.stat()]}
    if not binaries:
        return
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            # Unprivileged installs belong to this user. Root can check all.
            if os.geteuid() != 0 and process.stat().st_uid != os.geteuid():
                continue
            stat = (process / "exe").stat()
            if (stat.st_dev, stat.st_ino) in binaries:
                raise ValueError(f"DevSpace installation is running (PID {process.name}); quit it before installing")
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError as error:
            # Same-UID nondumpable helpers (e.g. systemd --user) can hide exe.
            # Keep checking other PIDs, but fail closed for DevSpace or when
            # even the process name cannot be determined.
            try:
                name = (process / "comm").read_text().strip()
            except (FileNotFoundError, ProcessLookupError):
                continue
            except OSError as name_error:
                raise ValueError(f"Cannot verify process {process.name}; installation left untouched") from name_error
            if name in {"DevSpace", "DevSpaceBackend"}:
                raise ValueError(f"Cannot verify running {name} (PID {process.name}); installation left untouched") from error


def install(bundle, prefix):
    bundle = bundle.resolve()
    prefix = prefix.resolve()
    destination = prefix / "lib/devspace"
    if not destination.parent.resolve().is_relative_to(prefix):
        raise ValueError("Refusing installation parent outside prefix")
    if not production_bundle(bundle):
        raise ValueError("Refusing input that is not a generated production bundle")
    if bundle == destination or destination in bundle.parents or bundle in destination.parents:
        raise ValueError("Refusing overlapping bundle and installation paths")
    if destination.exists() or destination.is_symlink():
        if not production_bundle(destination):
            raise ValueError(f"Refusing unrecognized installation: {destination}")
    icons = list((bundle / "share/icons/hicolor").glob(f"*/apps/{IDENTITY}.png"))
    if len(icons) != 1:
        raise ValueError("Refusing bundle without one application icon")
    for relative in ["bin/devspace", "bin/DevSpace", "bin/DevSpaceBackend",
                     f"share/applications/{IDENTITY}.desktop", "share/doc/devspace/LICENSE"]:
        if not (bundle / relative).is_file():
            raise ValueError(f"Refusing incomplete production bundle: {relative}")
    icon_relative = icons[0].relative_to(bundle)
    links = {prefix / "bin/devspace": destination / "bin/devspace",
             prefix / f"share/applications/{IDENTITY}.desktop": destination / f"share/applications/{IDENTITY}.desktop",
             prefix / icon_relative: destination / icon_relative}
    for link, target in links.items():
        if not link.parent.resolve().is_relative_to(prefix):
            raise ValueError(f"Refusing registration parent outside prefix: {link}")
        if (link.exists() or link.is_symlink()) and (not link.is_symlink() or link.readlink() != target):
            raise ValueError(f"Refusing to overwrite unrelated entry: {link}")
    refuse_running(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    created = []
    with tempfile.TemporaryDirectory(prefix=".devspace-install-", dir=destination.parent) as temporary:
        staging = Path(temporary) / "bundle"
        shutil.copytree(bundle, staging)
        desktop = staging / f"share/applications/{IDENTITY}.desktop"
        # Desktop Exec is not shell syntax: escape reserved characters and field
        # codes, including spaces/Unicode in a custom installation prefix.
        executable = str(destination / "bin/devspace").replace("%", "%%")
        for character in ["\\", '"', "`", "$"]:
            executable = executable.replace(character, "\\" + character)
        executable = executable.replace("\\", "\\\\")
        icon_value = str(prefix / icon_relative).replace("\\", "\\\\")
        # GIO resolves the executable before expanding %% field escapes. Keep
        # the executable fixed and put a percent-containing path in an argument.
        desktop.write_text(desktop.read_text().replace("Exec=devspace\n", f'Exec=/usr/bin/env "{executable}"\n')
                           .replace(f"Icon={IDENTITY}\n", f"Icon={icon_value}\n"))
        refuse_running(destination)
        replaced = destination.exists()
        # Keep recovery outside automatic staging cleanup if rollback fails.
        recovery = Path(tempfile.mkdtemp(prefix=".devspace-previous-", dir=destination.parent)) if replaced else None
        previous = recovery / "previous" if recovery else None
        try:
            if replaced:
                destination.rename(previous)
            staging.rename(destination)
            for link, target in links.items():
                if not link.is_symlink():
                    link.parent.mkdir(parents=True, exist_ok=True)
                    link.symlink_to(target)
                    created.append(link)
        except BaseException:
            for link in reversed(created):
                link.unlink()
            if destination.exists() and not staging.exists():
                destination.rename(staging)
            if previous and previous.exists():
                try:
                    previous.rename(destination)
                except OSError as error:
                    raise RuntimeError(f"Rollback failed; previous installation retained at {previous}") from error
            if recovery:
                recovery.rmdir()
            raise
        if recovery:
            shutil.rmtree(recovery)
    print(f"Installed {destination}\nLaunch: {prefix / 'bin/devspace'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--prefix", required=True, type=Path)
    args = parser.parse_args()
    try:
        prefix = args.prefix.expanduser().resolve()
        if prefix == Path("/") or any(ord(character) < 32 for character in str(prefix)):
            raise ValueError("Refusing unsafe installation prefix")
        install(args.bundle.absolute(), prefix)
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
