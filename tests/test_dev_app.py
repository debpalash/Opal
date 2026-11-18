"""Exercise the actual dev bundle packager with isolated toolchain commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class DevBundleTest(unittest.TestCase):
    def test_finder_bundle_copies_before_relinking_and_exposes_resources(self):
        with tempfile.TemporaryDirectory(prefix="opal-dev-bundle-") as directory:
            root = Path(directory)
            script = root / "scripts/dev-app.sh"
            script.parent.mkdir()
            shutil.copy2(Path(__file__).resolve().parents[1] / "scripts/dev-app.sh", script)
            binary = root / "zig-out/bin/opal"
            binary.parent.mkdir(parents=True)
            binary.write_text("original debug executable")
            (root / "libtorrent_wrapper.so").write_text("local wrapper")
            app = root / "dist/Opal-dev.app"
            executable = app / "Contents/MacOS/Opal"
            executable.parent.mkdir(parents=True)
            # Reproduce the previous packager's hardlinked output.
            os.link(binary, executable)
            resources = app / "Contents/Resources"
            resources.mkdir()
            (resources / "opal.icns").touch()
            for name in ("engines", "bin", "web", "assets/browser-integration", "data"):
                (root / name).mkdir(parents=True)
            (root / "engines/nova2.py").write_text("# fixture")
            for name in ("plugins-manifest.json", "manga-sources-sfw.json"):
                (root / "data" / name).write_text("{}")
            tools = root / "tools"
            tools.mkdir()
            # Patching must modify only the copied executable. Log the actual
            # dependency rewrite and signing order without needing macOS tools.
            patcher = tools / "install_name_tool"
            patcher.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >> "$PACKAGING_LOG"\nprintf "\\npatched" >> "${@: -1}"\n')
            signer = tools / "codesign"
            signer.write_text('#!/bin/bash\nprintf "sign %s\\n" "${@: -1}" >> "$PACKAGING_LOG"\n')
            patcher.chmod(0o755)
            signer.chmod(0o755)
            log = root / "packaging.log"
            result = subprocess.run(["bash", str(script)], cwd="/", text=True, capture_output=True,
                                    env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "PACKAGING_LOG": str(log)}, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(binary.read_text(), "original debug executable")
            self.assertNotEqual(binary.stat().st_ino, executable.stat().st_ino)
            self.assertIn("patched", executable.read_text())
            self.assertEqual((app / "Contents/Frameworks/libtorrent_wrapper.so").read_text(), "local wrapper")
            self.assertIn("@executable_path/../Frameworks/libtorrent_wrapper.so", log.read_text())
            self.assertEqual(log.read_text().splitlines()[-1], f"sign {app}")
            self.assertEqual((resources / "engines/nova2.py").read_text(), "# fixture")
            for name in ("scripts", "bin", "web", "plugins-manifest.json", "manga-sources-sfw.json", "browser-integration"):
                self.assertTrue((resources / name).is_symlink(), name)
            self.assertEqual(result.stdout.strip(), str(executable))


if __name__ == "__main__":
    unittest.main()
