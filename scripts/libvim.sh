#!/bin/sh
# Builds Vendor/build/libvim.a, the Vim core the vim module runs keys through, from the libvim
# submodule. SwiftPM links it but cannot build it, so bundle.sh and test.sh run this first; it
# reuses a library only if it supports both Intel and Apple Silicon.
#
# The sources are copied out before building, so the submodule stays clean.
#
# Usage: scripts/libvim.sh [--force]

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/Vendor/build"

if [ "${1:-}" != "--force" ] && [ -f "$out/libvim.a" ]; then
	case $(lipo -archs "$out/libvim.a" 2>/dev/null) in
		"arm64 x86_64"|"x86_64 arm64") exit 0 ;;
	esac
fi

if [ ! -f "$root/Vendor/libvim/src/libvim.h" ]; then
	git -C "$root" submodule update --init Vendor/libvim
fi

work="$out/src"
rm -rf "$work"
mkdir -p "$out"
cp -R "$root/Vendor/libvim" "$work"

# The Makefile builds with -Werror, and its configure step compiles test programs in pre-C99 style
# (implicit int and the like) that current clang rejects; both are told to let that through.
relaxed="-Wno-error=implicit-int -Wno-error=implicit-function-declaration -Wno-error=int-conversion"

(
	cd "$work/src"
	# With parallel make, distclean can remove auto/config.mk before testclean reads it.
	CFLAGS="-g -O2 $relaxed" make -j1 \
		WARN_FLAGS="-w $relaxed -Wno-error=incompatible-function-pointer-types" >"$out/build.log" 2>&1
) || {
	tail -20 "$out/build.log" >&2
	exit 1
}

cp "$work/src/libvim.a" "$out/libvim.a"
rm -rf "$work"
echo "$out/libvim.a"
