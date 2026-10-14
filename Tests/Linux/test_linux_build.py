"""Exercise the Swift Linux build path with controlled compiler products."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LinuxBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        shutil.copyfile(ROOT / "Makefile", self.directory / "Makefile")
        shutil.copytree(ROOT / "scripts", self.directory / "scripts",
                        ignore=shutil.ignore_patterns("*.pyc", "__pycache__"))
        shutil.copytree(ROOT / "Resources", self.directory / "Resources")
        shutil.copyfile(ROOT / "Info.plist", self.directory / "Info.plist")
        shutil.copyfile(ROOT / "LICENSE", self.directory / "LICENSE")
        if (ROOT / "Package.resolved").exists():
            shutil.copyfile(ROOT / "Package.resolved", self.directory / "Package.resolved")

        self.runtime = self.directory / "toolchain/usr/lib/swift/linux"
        self.runtime.mkdir(parents=True)
        (self.runtime / "libswiftCore.so").write_text("controlled runtime")
        notice = self.directory / "toolchain/usr/share/swift/LICENSE.txt"
        notice.parent.mkdir(parents=True)
        notice.write_text("Swift toolchain license fixture\n")

        self.app_program = (
            "#!/usr/bin/env python3\nimport json,os,sys\n"
            "print(json.dumps({'channel':os.environ['DEVSPACE_BUILD_CHANNEL'],"
            "'backend':os.environ['DEVSPACE_BACKEND'],"
            "'libraries':os.environ['LD_LIBRARY_PATH'],'args':sys.argv[1:]}))\n"
        )
        self.backend_program = (
            "#!/bin/sh\nif [ \"$1\" = --print-path ]; then "
            "printf '%s\\n' \"/usr/bin:/bin:$HOME/.local/bin\"; fi\n"
        )
        self.products = self.directory / "products.json"
        self.products.write_text(json.dumps({
            "DevSpaceLinuxApp": self.app_program,
            "DevSpaceLinuxBackend": self.backend_program,
        }))

        self.swift = self.directory / "swift"
        self.swift.write_text(
            "#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\n"
            "args=sys.argv[1:]\n"
            "with open('swift-products.jsonl','a') as log: log.write(json.dumps(args)+'\\n')\n"
            "if 'build' in args:\n"
            " product=args[args.index('--product')+1]\n"
            " if os.environ.get('DEVSPACE_TEST_FAIL_PRODUCT') == product: raise SystemExit(42)\n"
            " scratch=Path(args[args.index('--scratch-path')+1])\n"
            " configuration='release' if '-c' in args and args[args.index('-c')+1] == 'release' else 'debug'\n"
            " output=scratch/configuration/product\n"
            " output.parent.mkdir(parents=True,exist_ok=True)\n"
            " output.write_text(json.load(open(os.environ['DEVSPACE_TEST_PRODUCTS']))[product])\n"
            " output.chmod(0o755)\n"
        )
        self.swift.chmod(0o755)

        self.zig = self.directory / "zig"
        self.zig.write_text("#!/bin/sh\ntouch zig-was-invoked\nexit 99\n")
        self.zig.chmod(0o755)

    def run_make(self, target, *extra, fail_product=None):
        environment = dict(os.environ, DEVSPACE_TEST_PRODUCTS=str(self.products))
        if fail_product:
            environment["DEVSPACE_TEST_FAIL_PRODUCT"] = fail_product
        return subprocess.run(
            ["make", target, f"SWIFT={self.swift}", f"ZIG={self.zig}",
             f"LINUX_SWIFT_RUNTIME={self.runtime}", *extra],
            cwd=self.directory, env=environment, capture_output=True, text=True,
        )

    def test_linux_build_installs_swift_frontend_and_backend_without_zig(self):
        result = self.run_make("linux-build-dev")
        self.assertEqual(result.returncode, 0, result.stderr)
        products = [json.loads(line) for line in
                    (self.directory / "swift-products.jsonl").read_text().splitlines()]
        built_products = [args[args.index("--product") + 1] for args in products]
        self.assertEqual(built_products, ["DevSpaceLinuxApp", "DevSpaceLinuxBackend"])
        self.assertFalse((self.directory / "zig-was-invoked").exists())
        self.assertEqual((self.directory / "build/linux-dev/bin/DevSpaceLinuxApp").read_text(),
                         self.app_program)
        self.assertEqual((self.directory / "build/linux-dev/bin/DevSpaceLinuxBackend").read_text(),
                         self.backend_program)

    def test_backend_compile_failure_does_not_install_partial_frontend(self):
        result = self.run_make("linux-build-dev", fail_product="DevSpaceLinuxBackend")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / "build/linux-dev/bin/DevSpaceLinuxApp").exists())
        self.assertFalse((self.directory / "build/linux-dev/bin/DevSpaceLinuxBackend").exists())

    def test_linux_package_builds_production_products_and_preserves_macos_lockfile(self):
        copyright_file = self.directory / "debian-copyright"
        copyright_file.write_text(
            "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n"
            "Files: *\nCopyright: test only\nLicense: test\n"
        )
        swift_license = self.directory / "swift-LICENSE.txt"
        swift_license.write_text("Swift license test fixture\n")
        lockfile = (self.directory / "Package.resolved").read_bytes() if (self.directory / "Package.resolved").exists() else None
        package_output = self.directory / "build/devspace-test.deb"
        result = self.run_make(
            "linux-package",
            f"LINUX_PACKAGE_COPYRIGHT={copyright_file}",
            f"LINUX_SWIFT_LICENSE={swift_license}",
            "LINUX_PACKAGE_MAINTAINER=DevSpace test fixture <devspace@example.invalid>",
            f"LINUX_PACKAGE_OUTPUT={package_output}",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        products = [json.loads(line) for line in
                    (self.directory / "swift-products.jsonl").read_text().splitlines()]
        self.assertEqual([args[args.index("--product") + 1] for args in products],
                         ["DevSpaceLinuxApp", "DevSpaceLinuxBackend"])
        self.assertTrue(all(args[args.index("-c") + 1] == "release" for args in products))
        self.assertTrue(package_output.is_file())
        self.assertEqual(subprocess.check_output(["dpkg-deb", "-f", str(package_output), "Package"], text=True).strip(),
                         "devspace")
        if lockfile is not None:
            self.assertEqual((self.directory / "Package.resolved").read_bytes(), lockfile)

    def test_swiftpm_test_target_does_not_collect_standalone_integration_runners(self):
        manifest = (ROOT / "Package.swift").read_text()
        self.assertNotIn('name: "DevSpaceLinuxAppTests"', manifest,
                         "Tests/LinuxApp contains standalone @main runners, not one SwiftPM test module")

    def test_legacy_ghostty_zig_frontend_pipeline_is_retired(self):
        obsolete = (
            ROOT / "scripts/prepare-linux-frontend.py",
            ROOT / "scripts/prepare-linux-ghostty.py",
            ROOT / "Tests/Linux/test_frontend_install.py",
            ROOT / "Sources/Linux/backend_client.zig",
            ROOT / "Sources/Linux/gtk",
            ROOT / "Sources/Linux/patches",
            ROOT / "Sources/Linux/engine-patches",
        )
        remaining = [str(path.relative_to(ROOT)) for path in obsolete if path.exists()]
        self.assertEqual(remaining, [], f"obsolete Ghostty/Zig frontend remains: {remaining}")

    def test_run_rebuilds_and_replaces_a_relocatable_dev_bundle(self):
        for _ in range(2):
            result = self.run_make("linux-run")
            self.assertEqual(result.returncode, 0, result.stderr)
            output = result.stdout.splitlines()
            self.assertTrue(output, f"linux-run produced no output; stderr={result.stderr!r}")
            launched = None
            for line in reversed(output):
                try:
                    candidate = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(candidate, dict):
                    launched = candidate
                    break
            self.assertIsNotNone(launched,
                                 f"launcher did not emit its JSON probe; stdout={result.stdout!r}; "
                                 f"stderr={result.stderr!r}")
            bundle = self.directory / "build/linux-dev-bundle"
            self.assertEqual(launched["channel"], "development")
            self.assertEqual(launched["backend"], str(bundle / "bin/DevSpaceDevBackend"))
            self.assertEqual(launched["libraries"].split(":")[0], str(bundle / "lib"))
            self.assertTrue((bundle / "bin/DevSpaceDev").is_file())
            self.assertTrue((bundle / "bin/DevSpaceDevBackend").is_file())

    def test_linux_app_typechecks_against_system_gtk_and_vte_modules(self):
        compiler = os.environ.get("DEVSPACE_SWIFTC") or shutil.which("swiftc")
        self.assertIsNotNone(compiler, "Swift compiler must be installed")
        build = self.directory / "swift-modules"
        build.mkdir()
        module_map = ROOT / "Tests/Linux/fixtures/CPTY.modulemap"
        core_command = [compiler, "-emit-module", "-module-name", "DevSpaceCore",
                        "-emit-module-path", str(build / "DevSpaceCore.swiftmodule"),
                        "-module-cache-path", str(build / "core-module-cache"),
                        "-Xcc", f"-fmodule-map-file={module_map}",
                        "-I", str(ROOT / "Sources/CPTY/include"),
                        *map(str, sorted((ROOT / "Sources/Core").glob("*.swift")))]
        core = subprocess.run(core_command, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(core.returncode, 0, core.stderr)

        cflags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "gtk4", "vte-2.91-gtk4"], text=True
        ))
        command = [compiler, "-typecheck", *map(str, sorted((ROOT / "Sources/LinuxApp").glob("*.swift"))),
                   "-I", str(build), "-I", str(ROOT / "Sources/CPTY/include"),
                   "-Xcc", f"-fmodule-map-file={module_map}",
                   "-module-cache-path", str(build / "app-module-cache"),
                   "-I", str(ROOT / "Sources/LinuxGTK"), "-I", str(ROOT / "Sources/LinuxVTE")]
        for flag in cflags:
            command.extend(["-Xcc", flag])
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
