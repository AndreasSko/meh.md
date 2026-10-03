import json
from pathlib import Path
import tempfile
import unittest

from editor_performance_app_cache import cache_key, lookup, store


class ProbeAppCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.repo = self.root / "repo"
        self.sources = self.root / "selected"
        self.sources.mkdir()
        self.write("Sources/NoteCore/Document.swift", "core")
        self.write("meh.md/MarkdownSyntax.swift", "syntax")
        self.write("Tools/EditorQuoteCheck/Probe.swift", "probe")
        self.write("Tools/EditorQuoteCheck/Info.plist", "plist")
        self.write("Package.swift", "package")
        self.write("Package.resolved", "resolved")
        self.write("scripts/run_editor_performance_check.sh", "runner")
        self.write("scripts/editor_performance_app_cache.py", "helper")
        (self.sources / "MarkdownSyntax.swift").write_text("selected syntax")
        self.app = self.root / "built.app"
        self.app.mkdir()
        (self.app / "EditorQuoteCheck").write_bytes(b"compiled executable")
        (self.app / "Info.plist").write_text("plist")
        self.cache = self.root / "cache"

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def key(self, **changes):
        config = dict(compiler="Swift compiler build 1", sdk="/sdk/iPhoneSimulator27",
                      target="arm64-ios27-simulator", scenario="large-note", host="notebook")
        config.update(changes)
        return cache_key(self.repo, self.sources, **config)

    def test_same_inputs_reuse_verified_bundle(self):
        key = self.key()
        store(self.cache, key, self.app)
        destination = self.root / "run.app"
        self.assertTrue(lookup(self.cache, key, destination))
        self.assertEqual((destination / "EditorQuoteCheck").read_bytes(), b"compiled executable")
        self.assertFalse(lookup(self.cache, "f" * 64, self.root / "missing.app"))

    def test_each_production_input_edit_invalidates(self):
        for path in sorted(self.repo.rglob("*")):
            if path.is_file():
                with self.subTest(file=path.relative_to(self.repo)):
                    before = self.key()
                    text = path.read_text()
                    path.write_text(text + " changed")
                    self.assertNotEqual(before, self.key())
                    path.write_text(text)
        before = self.key()
        self.write("Sources/NoteCore/New.swift", "new production source")
        self.assertNotEqual(before, self.key())

    def test_selected_historical_source_and_relative_path_invalidate(self):
        before = self.key()
        path = self.sources / "MarkdownSyntax.swift"
        path.write_text("different historical source")
        self.assertNotEqual(before, self.key())
        before = self.key()
        path.rename(self.sources / "Renamed.swift")
        self.assertNotEqual(before, self.key())

    def test_toolchain_target_host_and_scenario_invalidate(self):
        original = self.key()
        for changes in ({"compiler": "Swift compiler build 2"}, {"sdk": "/new/sdk"},
                        {"target": "x86_64-ios27-simulator"}, {"host": "editor"},
                        {"scenario": "presentation"}):
            self.assertNotEqual(original, self.key(**changes))

    def test_binary_and_bundle_tamper_rejected_then_replaceable(self):
        key = self.key()
        for name in ("EditorQuoteCheck", "Info.plist"):
            store(self.cache, key, self.app)
            metadata = json.loads((self.cache / (key + ".json")).read_text())
            bundle = self.cache / metadata["entry"] / "Editor Quote Check.app"
            (bundle / name).write_bytes(b"tampered")
            destination = self.root / (name + ".app")
            self.assertFalse(lookup(self.cache, key, destination))
            self.assertFalse(destination.exists())
            store(self.cache, key, self.app)
            self.assertTrue(lookup(self.cache, key, destination))

    def test_bad_metadata_cannot_escape_cache(self):
        key = self.key()
        store(self.cache, key, self.app)
        manifest = self.cache / (key + ".json")
        manifest.write_text(json.dumps({"key": key, "entry": "../built.app"}))
        self.assertFalse(lookup(self.cache, key, self.root / "run.app"))
        manifest.write_text("not json")
        self.assertFalse(lookup(self.cache, key, self.root / "run.app"))


if __name__ == "__main__":
    unittest.main()
