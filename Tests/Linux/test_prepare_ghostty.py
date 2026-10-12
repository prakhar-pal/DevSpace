"""Exercise source preparation against real local archives, without downloads."""

import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "prepare-linux-ghostty.py"


class PrepareGhosttyTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".tmp"
        scratch.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.archive = self.directory / "source.tar.gz"
        self.manifest = self.directory / "source.json"
        self.output = self.directory / "upstream"
        self.contents = b'.{ .version = "1.3.1" }\n'
        self.make_archive("ghostty-1.3.1/build.zig.zon", self.contents)

    def make_archive(self, name, contents):
        with tarfile.open(self.archive, "w:gz") as bundle:
            member = tarfile.TarInfo(name)
            member.size = len(contents)
            bundle.addfile(member, io.BytesIO(contents))
        self.manifest.write_text(json.dumps({
            "version": "1.3.1",
            "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            "url": self.archive.as_uri(),
        }))

    def prepare(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--manifest", str(self.manifest),
             "--archive", str(self.archive), "--output", str(self.output)],
            capture_output=True, text=True,
        )

    def test_verified_source_is_extracted_without_changing_archive(self):
        # A missing extraction or modifying the upstream input breaks this contract.
        original = self.archive.read_bytes()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "ghostty-1.3.1/build.zig.zon").read_bytes(), self.contents)
        self.assertEqual(self.archive.read_bytes(), original)

    def test_checksum_mismatch_does_not_publish_source(self):
        # Removing verification would allow tampered archives into the build.
        manifest = json.loads(self.manifest.read_text())
        manifest["sha256"] = "0" * 64
        self.manifest.write_text(json.dumps(manifest))
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr.lower())
        self.assertFalse(self.output.exists())

    def test_existing_tree_is_not_overwritten(self):
        # Rerunning preparation must not discard local integration changes.
        existing = self.output / "ghostty-1.3.1/build.zig.zon"
        existing.parent.mkdir(parents=True)
        existing.write_bytes(b"local integration changes\n")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr.lower())
        self.assertEqual(existing.read_bytes(), b"local integration changes\n")

    def test_archive_with_unexpected_root_is_rejected(self):
        # Extracting a different version would silently break the pinned build.
        self.make_archive("ghostty-9.9.9/build.zig.zon", self.contents)
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected archive path", result.stderr.lower())
        self.assertFalse(self.output.exists())

    def test_rejected_link_does_not_leave_partial_source(self):
        # A late unsafe entry must not leave a buildable-looking partial tree.
        with tarfile.open(self.archive, "w:gz") as bundle:
            member = tarfile.TarInfo("ghostty-1.3.1/build.zig.zon")
            member.size = len(self.contents)
            bundle.addfile(member, io.BytesIO(self.contents))
            link = tarfile.TarInfo("ghostty-1.3.1/escape")
            link.type = tarfile.SYMTYPE
            link.linkname = "../../outside"
            bundle.addfile(link)
        manifest = json.loads(self.manifest.read_text())
        manifest["sha256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.manifest.write_text(json.dumps(manifest))
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertFalse((self.directory / "outside").exists())

    def test_source_can_be_downloaded_from_manifest_url(self):
        # Ignoring the manifest URL would prevent fresh builds from preparing source.
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--manifest", str(self.manifest),
             "--output", str(self.output)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "ghostty-1.3.1/build.zig.zon").read_bytes(), self.contents)

    def test_default_pin_rejects_an_unapproved_archive(self):
        # Making --manifest mandatory or trusting arbitrary local archives breaks default preparation.
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--archive", str(self.archive),
             "--output", str(self.output)],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr.lower())
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
