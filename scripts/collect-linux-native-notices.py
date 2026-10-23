#!/usr/bin/env python3
"""Collect pinned experimental renderer notices; never install or build a toolchain."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
GHOSTTY = "08a9518340e19487bd5fdf96963583fb32f0c41f"
SKIA = "5f8aa127c855a8aabdb5708454afd07deebae643"
EXTRA = {
    "simdutf-APACHE.txt": ("https://raw.githubusercontent.com/simdutf/simdutf/v9.0.0/LICENSE-APACHE",
        "3d34610fc6b5e1b0bfe4e2f36171c2d62c28ef05cb8d704f5a0073be41a43b3d"),
    "simdutf-MIT.txt": ("https://raw.githubusercontent.com/simdutf/simdutf/v9.0.0/LICENSE-MIT",
        "fc8dbc04e03ad4efc08a647ffe7f995b811a95bc04c0e85a56d5277c6593fa5f"),
    "uucode-Unicode.txt": ("https://raw.githubusercontent.com/jacobsandlund/uucode/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses/LICENSE_unicode",
        "1eda5a3b026870c737b22e8bcd4954338612c790db688242e003f41a4fa95175"),
    "uucode-Hoehrmann.txt": ("https://raw.githubusercontent.com/jacobsandlund/uucode/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses/LICENSE_Bjoern_Hoehrmann",
        "de219cece932aad5a817bf763393d8d149d378a15d2ad5320e3331eac07626dd"),
}
ARCHIVES = {
    "uucode-0.2.0-ZZjBPoGFVgCiflJNFc6Io8xzC67B6PA5bUkk4LT0kCxg": ["LICENSE.md"],
    "N-V-__8AAP5JWgCGP_AD0teWpa4krRvE9VPZzvviGdbmN4jI": ["LICENSE", "LICENSE-APACHE", "LICENSE-MIT"],
    "N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE": ["LICENSE", "LICENSE-BSD3"],
    "N-V-__8AADYiAAB_80AWnH1AxXC0tql9thT-R-DYO1gBqTLc": ["LICENSE"],
    "N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o": ["LICENSE"],
}


def collect(args):
    for source, revision in [(args.ghostty_source, GHOSTTY), (args.skia_source, SKIA)]:
        actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        if actual != revision:
            raise ValueError(f"Source revision mismatch: {source}: expected {revision}, found {actual}")
        if subprocess.run(["git", "-C", str(source), "diff", "--quiet", "HEAD"]).returncode != 0:
            raise ValueError(f"Tracked native source modifications must be reviewed before collecting notices: {source}")
    if args.output.exists() or args.output.is_symlink():
        raise ValueError("Notice output already exists; use a fresh staging directory")
    zig = shutil.which("zig")
    if not zig or subprocess.check_output([zig, "version"], text=True).strip() != "0.17.0":
        raise ValueError("The pinned globally installed Zig 0.17.0 is required")
    files = {
        "ghostty-LICENSE.txt": args.ghostty_source / "LICENSE",
        "skia-LICENSE.txt": args.skia_source / "LICENSE",
        "skcms-LICENSE.txt": args.skia_source / "modules/skcms/LICENSE",
        "khronos-GLSL-header.txt": args.skia_source / "src/sksl/GLSL.std.450.h",
        # Preserve embedded third-party notices too, not only the top-level MIT.
        "simdutf-vendored-header.txt": args.ghostty_source / "pkg/simdutf/vendor/simdutf.h",
        "simdutf-vendored-source.txt": args.ghostty_source / "pkg/simdutf/vendor/simdutf.cpp",
        "zig-LICENSE.txt": Path(zig).resolve().parent / "LICENSE",
        "zig-musl-COPYRIGHT.txt": Path(zig).resolve().parent / "lib/libc/musl/COPYRIGHT",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".native-notices-", dir=args.output.parent) as staging:
        staging = Path(staging)
        inventory = []
        def preserve(name, data, origin):
            if not data:
                raise ValueError(f"Empty notice: {origin}")
            (staging / name).write_bytes(data)
            inventory.append({"file": name, "source": origin, "sha256": hashlib.sha256(data).hexdigest()})
        for name, path in files.items():
            if path.is_relative_to(args.ghostty_source):
                origin = f"ghostty@{GHOSTTY}:{path.relative_to(args.ghostty_source)}"
            elif path.is_relative_to(args.skia_source):
                origin = f"skia@{SKIA}:{path.relative_to(args.skia_source)}"
            else:
                origin = f"Zig 0.17.0:{path.relative_to(Path(zig).resolve().parent)}"
            preserve(name, path.read_bytes(), origin)
        for index, (package, members) in enumerate(ARCHIVES.items()):
            archive_path = args.zig_cache / "p" / f"{package}.tar.gz"
            with tarfile.open(archive_path) as archive:
                for member in members:
                    # Read named regular members; never extract archive paths.
                    entry = archive.getmember(f"{package}/{member}")
                    if not entry.isfile():
                        raise ValueError(f"Notice archive member is not a file: {entry.name}")
                    preserve(f"ghostty-package-{index}-{member}.txt", archive.extractfile(entry).read(),
                             f"{archive_path.name}:{entry.name}")
        for name, (url, digest) in EXTRA.items():
            cached = args.extra_notices / name
            if cached.is_file():
                data = cached.read_bytes()
            elif args.fetch_missing:
                data = urlopen(url, timeout=30).read()
            else:
                raise ValueError(f"Missing {name}; provide --extra-notices or allow --fetch-missing")
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f"Notice checksum mismatch: {name}")
            preserve(name, data, url)
        manifest = {"renderer": "ghostty-skia", "distribution": "development-only",
                    "ghostty_revision": GHOSTTY, "skia_revision": SKIA, "zig_version": "0.17.0",
                    "notices": inventory,
                    "limitations": "Pinned experimental build inventory; not a shipping dependency-policy approval. System libraries retain distro notices."}
        artifacts = [args.ghostty_prefix / "lib/libghostty-vt.a", args.skia_source / "out/DevSpace/libskia.a",
                     args.skia_source / "out/DevSpace/libskcms.a"]
        manifest["native_artifacts"] = [{"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                                        for path in artifacts]
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        staging.rename(args.output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghostty-source", type=Path, default=ROOT / "references/ghostty")
    parser.add_argument("--skia-source", type=Path, default=Path(os.environ.get("SKIA_SOURCE", ROOT / ".tmp/ghostty-skia/skia")))
    parser.add_argument("--ghostty-prefix", type=Path, default=Path(os.environ.get("GHOSTTY_VT_PREFIX", ROOT / ".tmp/ghostty-skia/ghostty-vt")))
    parser.add_argument("--zig-cache", type=Path, default=ROOT / ".tmp/ghostty-skia/zig-global-cache")
    parser.add_argument("--extra-notices", type=Path, default=ROOT / ".tmp/ghostty-skia/native-notice-inputs")
    parser.add_argument("--fetch-missing", action="store_true")
    parser.add_argument("--output", required=True, type=Path)
    try:
        collect(parser.parse_args())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Native notices: {error}\n")
