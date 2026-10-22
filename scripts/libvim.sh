#!/bin/sh
# Builds Vendor/build/libvim.a, the Vim core the vim module runs keys through, from the libvim
# submodule. SwiftPM links it but cannot build it, so bundle.sh and test.sh run this first; it
# does nothing when the library is already there.
#
# The sources are copied out before building, so the submodule stays clean.
#
# Usage: scripts/libvim.sh [--force]

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/Vendor/build"

if [ -f "$out/libvim.a" ] && [ "${1:-}" != "--force" ]; then
	exit 0
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
	CFLAGS="-g -O2 $relaxed" make -j"$(sysctl -n hw.ncpu)" \
		WARN_FLAGS="-w $relaxed -Wno-error=incompatible-function-pointer-types" >"$out/build.log" 2>&1
) || {
	tail -20 "$out/build.log" >&2
	exit 1
}

cp "$work/src/libvim.a" "$out/libvim.a"
rm -rf "$work"
echo "$out/libvim.a"
