import tempfile
import unittest
import zipfile
from pathlib import Path

from package_ipa import write_ipa


class PackagingTests(unittest.TestCase):
    def test_debug_symbols_are_excluded_and_runtime_plugin_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "WebDriverAgentRunner-Runner.app"
            files = {
                "Info.plist": b"app metadata",
                "WebDriverAgentRunner-Runner": b"runner executable",
                "PlugIns/WebDriverAgentRunner.xctest/Info.plist": b"test metadata",
                "PlugIns/WebDriverAgentRunner.xctest/WebDriverAgentRunner": b"test executable",
                "PlugIns/WebDriverAgentRunner.xctest/Frameworks/WebDriverAgentLib.framework/WebDriverAgentLib": b"runtime framework",
                "PlugIns/WebDriverAgentRunner.xctest.dSYM/Contents/Resources/DWARF/WebDriverAgentRunner": b"debug executable",
                "PlugIns/WebDriverAgentRunner.xctest/Frameworks/WebDriverAgentLib.framework.dSYM/Contents/Info.plist": b"debug metadata",
                "Symbols/arm64.bcsymbolmap": b"debug symbol map",
            }
            for name, content in files.items():
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            ipa = root / "TouchBridge.ipa"
            write_ipa(app, ipa)
            with zipfile.ZipFile(ipa) as archive:
                names = archive.namelist()
                self.assertFalse(any(".dSYM" in name or name.endswith(".bcsymbolmap") for name in names))
                prefix = "Payload/WebDriverAgentRunner-Runner.app/"
                runtime = {prefix + name for name in files if ".dSYM" not in name and not name.endswith(".bcsymbolmap")}
                self.assertEqual(set(names), runtime)
                self.assertEqual(archive.read(prefix + "PlugIns/WebDriverAgentRunner.xctest/WebDriverAgentRunner"), b"test executable")
                self.assertIsNone(archive.testzip())


if __name__ == "__main__":
    unittest.main()
