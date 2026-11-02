"""No-weights regression tests for the unsigned IPA + user-supplied model packer."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "bundle-mw3-model-ipa.py"
spec = importlib.util.spec_from_file_location("bundle_mw3_model_ipa", SCRIPT)
bundler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundler)

class ModelBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.model = self.root / "VelmiraMW3.mlpackage"
        for required in bundler.REQUIRED_FILES:
            path = self.model / required
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = b"{}" if required == "Manifest.json" else (
                b"W" * 1_000_001 if required.endswith("weight.bin") else b"model")
            path.write_bytes(payload)
        self.source = self.root / "input.ipa"
        with zipfile.ZipFile(self.source, "w") as dst:
            dst.writestr("Payload/TPPlay.app/Info.plist", b"plist")
            dst.writestr("Payload/TPPlay.app/TPPlay", b"executable")

    def test_bundle_contains_real_model_paths(self):
        output = self.root / "complete.ipa"
        bundler.bundle(self.source, self.model, output)
        with zipfile.ZipFile(output) as archive:
            for name in bundler.REQUIRED_FILES:
                self.assertIn(
                    "Payload/TPPlay.app/VelmiraMW3.mlpackage/" + name,
                    archive.namelist())
            self.assertIsNone(archive.testzip())

    def test_rejects_model_without_weights(self):
        (self.model / bundler.REQUIRED_FILES[-1]).unlink()
        with self.assertRaises(ValueError):
            bundler.bundle(self.source, self.model, self.root / "broken.ipa")

    def test_rejects_wrong_application(self):
        with zipfile.ZipFile(self.source, "w") as archive:
            archive.writestr("Payload/Wrong.app/Info.plist", b"plist")
        with self.assertRaises(ValueError):
            bundler.bundle(self.source, self.model, self.root / "wrong.ipa")

if __name__ == "__main__":
    unittest.main()
