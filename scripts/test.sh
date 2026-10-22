#!/bin/sh
# Runs `swift test`, working around Command Line Tools without Xcode: the toolchain ships the Swift
# Testing macro plugin in a subdirectory that SwiftPM does not search, so `@Test` fails to expand.
# With full Xcode selected the extra flag is not needed and is not passed.

set -eu

plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"

if [ -d "$plugins" ]; then
	exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi

exec swift test "$@"
