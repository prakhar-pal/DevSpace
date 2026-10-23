"""Opt-in inventory checks using the actual pinned native build inputs."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/collect-linux-native-notices.py"
INPUTS = ROOT / ".tmp/ghostty-skia/native-notice-inputs"


@unittest.skipUnless(INPUTS.is_dir() and (ROOT / ".tmp/ghostty-skia/skia/out/DevSpace/libskia.a").is_file(),
                     "requires the pinned experimental native build")
class NativeNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.output = self.directory / "notices"

    def collect(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), "--output", str(self.output), *arguments],
                              cwd=ROOT, capture_output=True, text=True)

    def test_inventory_contains_matching_full_notices_and_native_artifact_hashes(self):
        result = self.collect()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["distribution"], "development-only")
        self.assertEqual(len(manifest["native_artifacts"]), 3)
        for entry in manifest["notices"]:
            self.assertEqual(hashlib.sha256((self.output / entry["file"]).read_bytes()).hexdigest(), entry["sha256"])
        for name in ["ghostty-LICENSE.txt", "skia-LICENSE.txt", "skcms-LICENSE.txt", "uucode-Unicode.txt",
                     "uucode-Hoehrmann.txt", "simdutf-MIT.txt", "simdutf-vendored-header.txt", "zig-musl-COPYRIGHT.txt"]:
            self.assertTrue((self.output / name).is_file(), name)

    def test_modified_cached_notice_fails_without_publishing_partial_inventory(self):
        modified = self.directory / "inputs"
        shutil.copytree(INPUTS, modified)
        (modified / "simdutf-MIT.txt").write_text("wrong notice")
        result = self.collect("--extra-notices", str(modified))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse(self.output.exists())

    def test_wrong_source_revision_is_rejected(self):
        result = self.collect("--ghostty-source", str(ROOT / ".tmp/ghostty-skia/skia"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("revision mismatch", result.stderr)
        self.assertFalse(self.output.exists())
