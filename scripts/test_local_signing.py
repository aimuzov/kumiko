from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class LocalSigningTests(unittest.TestCase):
    def test_local_app_entitlements_allow_loading_embedded_sparkle(self):
        app = ROOT / "dist/Kumiko.app"
        framework = app / "Contents/Frameworks/Sparkle.framework/Sparkle"
        self.assertTrue(framework.is_file(), "Build scripts/bundle.sh debug first")
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / "probe.c"
            source.write_text(
                '#include <dlfcn.h>\n#include <stdio.h>\n'
                'int main(int argc, char **argv) {\n'
                '  void *library = dlopen(argv[1], RTLD_NOW);\n'
                '  if (!library) { fprintf(stderr, "%s\\n", dlerror()); return 1; }\n'
                '  dlclose(library); return 0;\n}\n'
            )
            probe = folder / "probe"
            subprocess.run(["cc", str(source), "-o", str(probe)], check=True, capture_output=True)
            entitlements = subprocess.run(
                ["codesign", "--display", "--entitlements", "-", "--xml", str(app)],
                check=True, capture_output=True,
            ).stdout
            values = plistlib.loads(entitlements) if entitlements else {}
            self.assertTrue(
                values.get("com.apple.security.cs.disable-library-validation", False),
                "A local bundle without an Apple Team ID must allow its embedded Sparkle library",
            )
            signing = ["codesign", "--force", "--options", "runtime", "--sign", "-"]
            if entitlements:
                path = folder / "entitlements.plist"
                path.write_bytes(entitlements)
                signing.extend(["--entitlements", str(path)])
            subprocess.run([*signing, str(probe)], check=True, capture_output=True)
            result = subprocess.run([str(probe), str(framework)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
