#!/bin/sh
# Builds dist/Kumiko.app from the SwiftPM products.
#
# SwiftPM cannot produce an app bundle itself, and launch at login (SMAppService) and stable TCC
# permissions both need one. The CLI goes inside the bundle too, next to the app binary, so a
# Homebrew cask can link it onto the PATH.
#
# Signing: KUMIKO_SIGN_IDENTITY names the identity, a Developer ID for a release. Without it the
# local certificate from scripts/dev-certificate.sh is used when it exists, so permissions survive
# rebuilds; failing that the bundle is signed ad hoc, and macOS asks for Accessibility and Input
# Monitoring again after every rebuild.
#
# Usage: scripts/bundle.sh [debug|release]

set -eu

configuration=${1:-release}
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/dist/Kumiko.app"

# The vim module links libvim, which SwiftPM cannot build itself.
"$root/scripts/libvim.sh" >/dev/null
# The scripting addition is C built for Dock's arm64e, which SwiftPM cannot target either.
osax=$("$root/scripts/osax.sh")

version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$root/Sources/KumikoCore/Version.swift")
identifier=$(sed -n 's/.*static let bundleIdentifier = "\(.*\)".*/\1/p' "$root/Sources/KumikoCore/Version.swift")
sparkle_key=$(cat "$root/Resources/sparkle-public-key")
if ! printf '%s' "$sparkle_key" | /usr/bin/base64 -D > /dev/null 2>&1 ||
	[ "$(printf '%s' "$sparkle_key" | /usr/bin/base64 -D | wc -c | tr -d ' ')" != 32 ]; then
	echo "Resources/sparkle-public-key must contain a base64-encoded Ed25519 public key" >&2
	exit 1
fi

swift build --package-path "$root" -c "$configuration"
bin=$(swift build --package-path "$root" -c "$configuration" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"

cp "$bin/KumikoApp" "$app/Contents/MacOS/KumikoApp"
cp "$bin/kumiko" "$app/Contents/MacOS/kumiko"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
# `kumiko sa install` copies these into /Library/ScriptingAdditions and signs them there.
cp -R "$osax" "$app/Contents/Resources/osax"

# The icon is drawn by code at each size, so there is no picture of it to keep in the repository.
iconset=$(mktemp -d)/AppIcon.iconset
swift "$root/scripts/app-icon.swift" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>KumikoApp</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
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
	<key>SUFeedURL</key>
	<string>https://github.com/aimuzov/kumiko/releases/download/updates/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>$sparkle_key</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUAllowsAutomaticUpdates</key>
	<false/>
	<key>SUAutomaticallyUpdate</key>
	<false/>
	<key>SUSendProfileInfo</key>
	<false/>
</dict>
</plist>
PLIST

local_identity="Kumiko Local Development"

if [ -n "${KUMIKO_SIGN_IDENTITY:-}" ]; then
	identity=$KUMIKO_SIGN_IDENTITY
elif security find-certificate -c "$local_identity" >/dev/null 2>&1; then
	identity=$local_identity
else
	identity=-
fi

# SwiftPM records the deployment target as the SDK the binaries were built with. macOS gives the
# current look (Liquid Glass, the larger window corners) only to apps built with a current SDK, so
# the real SDK version goes in before signing.
sdk=$(xcrun --show-sdk-version)
for binary in "$app/Contents/MacOS/KumikoApp" "$app/Contents/MacOS/kumiko"; do
	xcrun vtool -set-build-version macos 14.0 "$sdk" -replace -output "$binary" "$binary"
done

framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for code in "$framework/Autoupdate" "$framework/Updater.app" \
	"$framework/XPCServices/Downloader.xpc" "$framework/XPCServices/Installer.xpc" \
	"$app/Contents/Frameworks/Sparkle.framework"; do
	codesign --force --options runtime --preserve-metadata=entitlements --sign "$identity" "$code"
done

# Signing the bundle seals the CLI and the updater inside it.
codesign --force --options runtime --sign "$identity" "$app/Contents/MacOS/kumiko"
codesign --force --options runtime --sign "$identity" "$app"

# Crashes reach Sentry as addresses, and only the debug symbols of the very binary that crashed
# turn them back into code. A release shipped without them is a release whose crashes nobody can
# read, so a signed build stops rather than skip the upload.
if [ "$configuration" = release ]; then
	dsym="$root/dist/KumikoApp.dSYM"
	rm -rf "$dsym"
	dsymutil "$bin/KumikoApp" -o "$dsym"

	if [ -n "${SENTRY_AUTH_TOKEN:-}" ]; then
		sentry-cli debug-files upload --org "${SENTRY_ORG:-f7b8dd6b2ecf}" --project kumiko --include-sources "$dsym" >&2
	elif [ -n "${KUMIKO_SIGN_IDENTITY:-}" ]; then
		echo "SENTRY_AUTH_TOKEN is not set: crash reports from this build would be unreadable" >&2
		exit 1
	fi
fi

echo "$app"
