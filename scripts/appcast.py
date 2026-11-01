import argparse
import base64
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parent.parent
FEED = "https://github.com/aimuzov/kumiko/releases/download/updates/appcast.xml"
SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def create_appcast(tag, archive, output, private_key, public_key, sparkle_bin, notes=None):
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Only stable vMAJOR.MINOR.PATCH tags can be published")
    version = tag[1:]
    if archive.name != f"Kumiko-{version}.zip":
        raise ValueError("Archive filename must match the release version")
    if output.exists():
        raise ValueError("Output directory must not already exist")
    expected_key = public_key.read_text().strip()
    if len(base64.b64decode(expected_key, validate=True)) != 32:
        raise ValueError("Invalid public key")
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read("Kumiko.app/Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != "online.aimuzov.kumiko":
        raise ValueError("Archive does not contain Kumiko")
    if info.get("CFBundleVersion") != version or info.get("CFBundleShortVersionString") != version:
        raise ValueError("Bundle version must match the release version")
    if info.get("SUPublicEDKey") != expected_key:
        raise ValueError("Bundle public key does not match the release public key")
    if info.get("SUFeedURL") != FEED:
        raise ValueError("Bundle must use the stable update feed")
    if info.get("SUAllowsAutomaticUpdates") is not False:
        raise ValueError("Updates must require confirmation")
    if not private_key.is_file():
        raise ValueError("Private signing key file is missing")

    download_prefix = f"https://github.com/aimuzov/kumiko/releases/download/{tag}/"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="kumiko-appcast-", dir=output.parent) as directory:
        staging = Path(directory)
        staged_archive = staging / archive.name
        shutil.copyfile(archive, staged_archive)
        if notes:
            shutil.copyfile(notes, staged_archive.with_suffix(".md"))
        subprocess.run([
            str(sparkle_bin / "generate_appcast"), "--ed-key-file", str(private_key),
            "--download-url-prefix", download_prefix,
            "--link", f"https://github.com/aimuzov/kumiko/releases/tag/{tag}",
            "--embed-release-notes", "--maximum-deltas", "0", str(staging),
        ], check=True)
        feed = staging / "appcast.xml"
        tree = ET.parse(feed)
        items = tree.findall("./channel/item")
        if len(items) != 1:
            raise ValueError("Expected one signed update in the generated feed")
        item = items[0]
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise ValueError("Generated update has no archive")
        signature = enclosure.get(SPARKLE_NS + "edSignature", "")
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Generated update is not signed")
        if enclosure.get("url") != download_prefix + archive.name or enclosure.get("length") != str(archive.stat().st_size):
            raise ValueError("Generated update does not match the release archive")
        if item.findtext(SPARKLE_NS + "version") != version:
            raise ValueError("Generated update does not match the release version")
        subprocess.run([
            str(sparkle_bin / "sign_update"), "--verify", "--ed-key-file", str(private_key),
            str(archive), signature,
        ], check=True)
        output.mkdir()
        shutil.copyfile(feed, output / "appcast.xml")
    return output / "appcast.xml"


def main():
    parser = argparse.ArgumentParser(description="Prepare a signed Sparkle feed from a final Kumiko release ZIP")
    parser.add_argument("tag")
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--private-key-file", type=Path, required=True)
    parser.add_argument("--public-key-file", type=Path, default=ROOT / "Resources/sparkle-public-key")
    parser.add_argument("--sparkle-bin", type=Path, default=ROOT / ".build/artifacts/sparkle/Sparkle/bin")
    parser.add_argument("--release-notes", type=Path)
    args = parser.parse_args()
    try:
        feed = create_appcast(args.tag, args.archive.resolve(), args.output.resolve(), args.private_key_file.resolve(),
                              args.public_key_file.resolve(), args.sparkle_bin.resolve(), args.release_notes)
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, zipfile.BadZipFile, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Cannot publish update: {error}\n")
    print(feed)


if __name__ == "__main__":
    main()
