#!/bin/sh
# Builds the scripting addition into Vendor/build/osax: the payload Dock loads and the loader that
# puts it there. Dock is arm64e, so both are built for it as well as for Intel, the way yabai
# builds its own. bundle.sh copies them into the app, `kumiko sa install` from there into
# /Library/ScriptingAdditions.
#
# Usage: scripts/osax.sh

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/Sources/KumikoOSAX"
out="$root/Vendor/build/osax"

mkdir -p "$out"

xcrun clang "$src/payload.m" -shared -fPIC -O2 -mmacosx-version-min=14.0 -arch x86_64 -arch arm64e \
	-F/System/Library/PrivateFrameworks -framework SkyLight -framework Foundation -o "$out/payload"
xcrun clang "$src/loader.m" -O2 -mmacosx-version-min=14.0 -arch x86_64 -arch arm64e \
	-framework Cocoa -o "$out/loader"

echo "$out"
