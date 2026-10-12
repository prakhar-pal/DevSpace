#!/usr/bin/env python3
"""Apply the maintained patch series to a new copy of verified Ghostty source."""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--patches", type=Path, default=ROOT / "Sources/Linux/patches")
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.exit(1, f"Output already exists: {output}; existing work was left intact.\n")
    if not args.upstream.is_dir():
        parser.exit(1, f"Upstream source directory not found: {args.upstream}\n")
    patches = sorted(args.patches.glob("*.patch"))
    if not patches:
        parser.exit(1, f"No patches found in {args.patches}\n")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".devspace-frontend-", dir=output.parent) as temporary:
        working = Path(temporary) / "source"
        shutil.copytree(args.upstream, working, symlinks=True)
        for patch in patches:
            result = subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p1",
                                     "-i", str(patch.absolute())], cwd=working,
                                    capture_output=True, text=True)
            if result.returncode:
                parser.exit(1, f"Patch failed: {patch.name}\n{result.stdout}{result.stderr}")
        for source, name in ((ROOT / "Sources/Linux/backend_client.zig", "devspace_backend_client.zig"),
                             (ROOT / "Sources/Linux/backend_protocol.zig", "backend_protocol.zig"),
                             (ROOT / "Tests/Linux/gtk_terminal_test.zig", "devspace_gtk_test.zig")):
            shutil.copyfile(source, working / "src" / name)
        working.rename(output)
    print(output)


if __name__ == "__main__":
    main()
