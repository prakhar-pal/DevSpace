#!/usr/bin/env python3
"""Prepare the pinned Ghostty source tree for the Linux integration."""

import argparse
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
from urllib.request import urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest", type=Path,
        default=Path(__file__).resolve().parents[1] / "Sources/Linux/ghostty-source.json",
    )
    parser.add_argument("--archive", help="Use a local archive instead of downloading it")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)
    if output.exists() or output.is_symlink():
        parser.exit(1, f"Output already exists: {output}; leave it intact or choose another directory.\n")
    manifest = json.loads(Path(args.manifest).read_text())
    output.parent.mkdir(parents=True, exist_ok=True)
    with ExitStack() as stack:
        if args.archive:
            source = stack.enter_context(open(args.archive, "rb"))
        else:
            source = stack.enter_context(tempfile.TemporaryFile(dir=output.parent))
            with urlopen(manifest["url"], timeout=60) as response:
                shutil.copyfileobj(response, source)
            source.seek(0)
        digest = hashlib.file_digest(source, "sha256").hexdigest()
        if digest != manifest["sha256"]:
            parser.exit(1, "Ghostty checksum mismatch; source was not extracted.\n")
        source.seek(0)
        archive = stack.enter_context(tarfile.open(fileobj=source, mode="r:gz"))
        expected_root = f"ghostty-{manifest['version']}"
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != expected_root:
                parser.exit(1, f"Unexpected archive path: {member.name}; source was not extracted.\n")
        with tempfile.TemporaryDirectory(prefix=".ghostty-", dir=output.parent) as staging:
            extracted = Path(staging) / "source"
            archive.extractall(extracted, filter="data")
            extracted.rename(output)


if __name__ == "__main__":
    main()
