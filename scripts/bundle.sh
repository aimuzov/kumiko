#!/bin/sh
# Builds dist/Kumiko.app from the SwiftPM products.
#
# SwiftPM cannot produce an app bundle itself, and launch at login (SMAppService) and stable TCC
# permissions both need one. The CLI goes inside the bundle too, next to the app binary, so a
# Homebrew cask can link it onto the PATH.
#
# Signing: set KUMIKO_SIGN_IDENTITY to a Developer ID to sign for real. Without it the bundle is
# signed ad hoc, which works locally, but macOS ties permissions to the exact build, so every
# rebuild asks for Accessibility and Input Monitoring again.
#
# Usage: scripts/bundle.sh [debug|release]

set -eu

configuration=${1:-release}
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/dist/Kumiko.app"

version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$root/Sources/KumikoCore/Version.swift")
identifier=$(sed -n 's/.*static let bundleIdentifier = "\(.*\)".*/\1/p' "$root/Sources/KumikoCore/Version.swift")

swift build --package-path "$root" -c "$configuration"
bin=$(swift build --package-path "$root" -c "$configuration" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin/KumikoApp" "$app/Contents/MacOS/KumikoApp"
cp "$bin/kumiko" "$app/Contents/MacOS/kumiko"

cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>KumikoApp</string>
	<key>CFBundleIdentifier</key>
	<string>$identifier</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Kumiko</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

identity=${KUMIKO_SIGN_IDENTITY:--}
# The CLI is signed first: signing the bundle seals what is inside it.
codesign --force --options runtime --sign "$identity" "$app/Contents/MacOS/kumiko"
codesign --force --options runtime --sign "$identity" "$app"

echo "$app"
