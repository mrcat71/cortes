"""Check the mounted installer, not just hdiutil's image checksum."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile

from ds_store import DSStore


def verify_layout(root, version):
    app = root / "Cortes.app"
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if info.get(key) != version:
            raise ValueError(f"Installer {key} does not match {version}")
    shortcut = root / "Applications"
    if not shortcut.is_symlink() or shortcut.readlink() != Path("/Applications"):
        raise ValueError("Installer has no shortcut to /Applications")
    if not (root / ".background.tiff").is_file():
        raise ValueError("Installer has no installation-arrow background")
    if (app / "Contents/Resources/CortesKit_CortesKit.bundle/Contents/Resources/Scenarios").exists():
        raise ValueError("Installer contains demo scenarios")
    with DSStore.open(str(root / ".DS_Store"), "r") as layout:
        if layout["Cortes.app"]["Iloc"] != (140, 120) or layout["Applications"]["Iloc"] != (500, 120):
            raise ValueError("Installer icons are not laid out on either side of the arrow")
        icons = layout["."]["icvp"]
        if icons["backgroundType"] != 2 or icons["iconSize"] != 128 or icons["arrangeBy"] != "none":
            raise ValueError("Installer is not configured for the drag-and-drop icon view")
        window = layout["."]["bwsp"]
        if window["ShowToolbar"] or window["ShowSidebar"]:
            raise ValueError("Finder chrome obscures the installation layout")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("version")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="cortes-dmg-check-") as directory:
        root = Path(directory)
        subprocess.run([
            "hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", str(root), str(args.image.resolve()),
        ], check=True, stdout=subprocess.DEVNULL, timeout=60)
        try:
            verify_layout(root, args.version)
            subprocess.run([
                "codesign", "--verify", "--deep", "--strict", str(root / "Cortes.app"),
            ], check=True, timeout=60)
        finally:
            subprocess.run(["hdiutil", "detach", str(root)], check=True, timeout=60)
    print(f"Verified {args.image.name}: signed Cortes {args.version}, Applications shortcut and arrow layout")


if __name__ == "__main__":
    main()
