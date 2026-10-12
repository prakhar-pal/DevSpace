"""Check atomic preparation of the maintained GTK source adaptation."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/prepare-linux-frontend.py"


class PrepareFrontendTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.upstream = self.directory / "upstream"
        (self.upstream / "src").mkdir(parents=True)
        (self.upstream / "example").write_text("original\ncontext\n")
        self.patches = self.directory / "patches"
        self.patches.mkdir()
        (self.patches / "0001-example.patch").write_text(
            "--- a/example\n+++ b/example\n@@ -1,2 +1,2 @@\n-original\n+adapted\n context\n")
        self.output = self.directory / "working"

    def prepare(self):
        return subprocess.run([sys.executable, str(SCRIPT), "--upstream", str(self.upstream),
                               "--patches", str(self.patches), "--output", str(self.output)],
                              capture_output=True, text=True)

    def test_applies_patches_and_copies_current_integration_without_changing_upstream(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "example").read_text(), "adapted\ncontext\n")
        self.assertEqual((self.upstream / "example").read_text(), "original\ncontext\n")
        for source, target in (("Sources/Linux/backend_client.zig", "devspace_backend_client.zig"),
                               ("Sources/Linux/backend_protocol.zig", "backend_protocol.zig"),
                               ("Tests/Linux/gtk_terminal_test.zig", "devspace_gtk_test.zig")):
            self.assertEqual((self.output / "src" / target).read_bytes(), (ROOT / source).read_bytes())

    def test_patch_failure_does_not_publish_a_partial_tree(self):
        (self.upstream / "example").write_text("changed\ncontext\n")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Patch failed", result.stderr)
        self.assertFalse(self.output.exists())
        self.assertEqual((self.upstream / "example").read_text(), "changed\ncontext\n")

    def test_fuzzy_context_is_rejected(self):
        (self.upstream / "example").write_text("original\nchanged-context\n")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Patch failed", result.stderr)
        self.assertFalse(self.output.exists())

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        (self.output / "local").write_text("keep my work\n")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual((self.output / "local").read_text(), "keep my work\n")

    def test_empty_patch_series_is_not_silently_accepted(self):
        (self.patches / "0001-example.patch").unlink()
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No patches found", result.stderr)
        self.assertFalse(self.output.exists())
