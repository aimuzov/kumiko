import base64
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
SPARKLE = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
FEED = "https://github.com/aimuzov/kumiko/releases/download/updates/appcast.xml"
SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.key = self.root / "private.key"
        self.key.write_bytes(base64.b64encode(SEED))
        self.key.chmod(0o600)
        self.public = self.root / "public.key"
        self.public.write_bytes(base64.b64encode(PUBLIC))

    def archive(self, **changes):
        info = {
            "CFBundleIdentifier": "online.aimuzov.kumiko",
            "CFBundleName": "Kumiko",
            "CFBundleExecutable": "KumikoApp",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1.2.3",
            "CFBundleShortVersionString": "1.2.3",
            "LSMinimumSystemVersion": "14.0",
            "SUPublicEDKey": base64.b64encode(PUBLIC).decode(),
            "SUFeedURL": FEED,
            "SUAllowsAutomaticUpdates": False,
        }
        info.update(changes)
        contents = self.root / "Kumiko.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["cp", "/usr/bin/true", str(contents / "MacOS/KumikoApp")], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(contents.parent)], check=True, capture_output=True)
        archive = self.root / "Kumiko-1.2.3.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(contents.parent), str(archive)], check=True)
        return archive

    def run_appcast(self, archive, tag="v1.2.3", private_key=None):
        return subprocess.run(
            ["python3", str(ROOT / "scripts/appcast.py"), tag, str(archive), str(self.root / "output"),
             "--private-key-file", str(private_key or self.key), "--public-key-file", str(self.public)],
            text=True, capture_output=True,
        )

    def test_feed_pins_the_signed_archive_and_disables_silent_installation(self):
        archive = self.archive()
        result = self.run_appcast(archive)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        feed = ET.parse(self.root / "output/appcast.xml")
        enclosure = feed.find("./channel/item/enclosure")
        self.assertEqual(enclosure.attrib["url"], "https://github.com/aimuzov/kumiko/releases/download/v1.2.3/Kumiko-1.2.3.zip")
        self.assertEqual(int(enclosure.attrib["length"]), archive.stat().st_size)
        signature = enclosure.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"]
        verify = subprocess.run([str(SPARKLE / "sign_update"), "--verify", "--ed-key-file", str(self.key), str(archive), signature], capture_output=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self.assertEqual(feed.findtext("./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}version"), "1.2.3")
        self.assertEqual(feed.findtext("./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}minimumSystemVersion"), "14.0")
        self.assertEqual(list((self.root / "output").iterdir()), [self.root / "output/appcast.xml"])

    def test_mismatched_tag_is_rejected_without_publishing_a_feed(self):
        result = self.run_appcast(self.archive(), tag="v1.2.4")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release version", result.stderr)
        self.assertFalse((self.root / "output/appcast.xml").exists())

    def test_archive_with_an_unexpected_public_key_is_rejected(self):
        result = self.run_appcast(self.archive(SUPublicEDKey=base64.b64encode(bytes(32)).decode()))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("public key", result.stderr)
        self.assertFalse((self.root / "output/appcast.xml").exists())

    def test_mismatched_private_key_cannot_produce_a_feed(self):
        wrong_key = self.root / "wrong.key"
        wrong_key.write_bytes(base64.b64encode(bytes(32)))
        result = self.run_appcast(self.archive(), private_key=wrong_key)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed", result.stderr)
        self.assertFalse((self.root / "output/appcast.xml").exists())

    def test_silent_installation_cannot_be_enabled_in_a_published_build(self):
        result = self.run_appcast(self.archive(SUAllowsAutomaticUpdates=True))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("confirmation", result.stderr)
        self.assertFalse((self.root / "output/appcast.xml").exists())

    def test_prerelease_is_rejected(self):
        result = self.run_appcast(self.archive(), tag="v1.2.3-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stable", result.stderr)
        self.assertFalse((self.root / "output/appcast.xml").exists())


if __name__ == "__main__":
    unittest.main()
