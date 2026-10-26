"""Validate interface catalogs without launching Cortes or reading user data."""

import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def catalog(code):
    path = ROOT / "App" / "Resources" / f"{code}.lproj" / "Localizable.strings"
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)], text=True))


class LocalizationTests(unittest.TestCase):
    def test_catalogs_have_matching_keys_and_format_arguments(self):
        english = catalog("en")
        for code in ("ru", "es"):
            translated = catalog(code)
            self.assertEqual(english.keys(), translated.keys(), code)
            for key, value in translated.items():
                self.assertTrue(value.strip(), (code, key))
                self.assertEqual(re.findall(r"%(?:lld|@|d|f)", english[key]),
                                 re.findall(r"%(?:lld|@|d|f)", value), (code, key))

    def test_bundled_voice_names_and_strategies_are_translated(self):
        english = catalog("en")
        resources = ROOT / "Packages" / "CortesKit" / "Sources" / "CortesKit" / "Resources"
        for folder in ("Voices", "BusinessVoices"):
            for path in (resources / folder).glob("*.json"):
                voice = json.loads(path.read_text())
                self.assertIn(voice["name"], english)
                for strategy in voice["strategies"]:
                    self.assertIn(strategy.replace("_", " "), english)

    def test_static_interface_labels_have_catalog_entries(self):
        english = catalog("en")
        technical_labels = {"Cortes", "z.ai", "en-US, ru-RU, es-ES"}
        pattern = r'\b(?:Text|Button|Toggle|Picker|Section|LabeledContent|Label|TextField|SecureField|Menu)\("((?:[^"\\]|\\.)*)"'
        for relative in ("App/Settings/SettingsView.swift", "App/Overlay/OverlayView.swift", "App/CortesApp.swift"):
            for key in re.findall(pattern, (ROOT / relative).read_text()):
                if r"\(" in key or key in technical_labels or not re.search("[a-zA-Z]", key):
                    continue
                self.assertIn(key, english, (relative, key))


if __name__ == "__main__":
    unittest.main()
