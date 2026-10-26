from pathlib import Path
import hashlib
import os
import plistlib
import runpy
import subprocess
import tempfile
import unittest

from ds_store import DSStore

from importlib.util import module_from_spec, spec_from_file_location

SCRIPT_DIR = Path(__file__).resolve().parent
spec = spec_from_file_location("verify_dmg", SCRIPT_DIR / "verify-dmg.py")
verifier = module_from_spec(spec)
spec.loader.exec_module(verifier)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        contents = self.root / "Cortes.app/Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as destination:
            plistlib.dump({"CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "0.1.1"}, destination)
        (self.root / "Applications").symlink_to("/Applications")
        (self.root / ".background.tiff").touch()
        settings = runpy.run_path(str(SCRIPT_DIR / "dmg-settings.py"), init_globals={"defines": {"app": str(contents.parent)}})
        self.settings = settings
        with DSStore.open(str(self.root / ".DS_Store"), "w+") as layout:
            for name, location in settings["icon_locations"].items():
                layout[name]["Iloc"] = location
            layout["."]["icvp"] = {"backgroundType": 2, "iconSize": settings["icon_size"], "arrangeBy": "none"}
            layout["."]["bwsp"] = {"ShowToolbar": settings["show_toolbar"], "ShowSidebar": settings["show_sidebar"]}

    def test_accepts_drag_and_drop_layout(self):
        verifier.verify_layout(self.root, "0.1.1")

    def test_does_not_modify_signed_app_finder_metadata(self):
        self.assertNotIn("Cortes.app", self.settings.get("hide_extensions", []))
        self.assertNotIn("Cortes.app", self.settings.get("hide", []))

    def test_rejects_wrong_app_version(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            verifier.verify_layout(self.root, "0.1.2")

    def test_rejects_wrong_install_destination(self):
        (self.root / "Applications").unlink()
        (self.root / "Applications").symlink_to("/tmp")
        with self.assertRaisesRegex(ValueError, "shortcut"):
            verifier.verify_layout(self.root, "0.1.1")

    def test_rejects_overlapping_icons(self):
        with DSStore.open(str(self.root / ".DS_Store"), "r+") as layout:
            layout["Applications"]["Iloc"] = (140, 120)
        with self.assertRaisesRegex(ValueError, "icons"):
            verifier.verify_layout(self.root, "0.1.1")

    def test_rejects_demo_resources(self):
        scenarios = self.root / "Cortes.app/Contents/Resources/CortesKit_CortesKit.bundle/Contents/Resources/Scenarios"
        scenarios.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "demo scenarios"):
            verifier.verify_layout(self.root, "0.1.1")

    def test_appcast_keeps_dmg_checksum_but_stages_only_zip(self):
        # Stub signing tools: this tests archive selection and checksum preservation,
        # not cryptography (the real Sparkle tools verify signatures in release CI).
        dist = self.root / "dist"
        dist.mkdir()
        archive = dist / "cortes-0.1.1-macos-arm64.zip"
        image = dist / "cortes-0.1.1-macos-arm64.dmg"
        archive.write_bytes(b"update zip")
        image.write_bytes(b"drag-and-drop installer")
        tools = self.root / "tools"
        tools.mkdir()
        stubs = {
            "generate_appcast": '#!/bin/bash\nset -eu\nfor stage in "$@"; do :; done\ntest -f "$stage/cortes-0.1.1-macos-arm64.zip"\ntest ! -e "$stage/cortes-0.1.1-macos-arm64.dmg"\nprintf "<rss/>" > "$stage/appcast.xml"\n',
            "sign_update": "#!/bin/bash\nexit 0\n",
            "swift": "#!/bin/bash\nexit 0\n",
        }
        for name, body in stubs.items():
            tool = tools / name
            tool.write_text(body)
            tool.chmod(0o755)
        environment = dict(os.environ, SPARKLE_ED_PRIVATE_KEY="test-only", PATH=f"{tools}{os.pathsep}{os.environ['PATH']}")
        subprocess.run([
            "bash", str(SCRIPT_DIR / "make-appcast.sh"), "0.1.1", str(self.root / "Cortes.app"), str(tools),
        ], cwd=self.root, env=environment, check=True)
        checksums = dict(line.split(maxsplit=1)[::-1] for line in (dist / "SHA256SUMS").read_text().splitlines())
        for file in (archive, image, dist / "appcast.xml"):
            self.assertEqual(checksums[file.name], hashlib.sha256(file.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
