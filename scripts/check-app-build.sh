#!/bin/sh
set -eu

# Checks that a built Runnir.app is the build it was meant to be (B47): its
# bundle ID, its RunnirBuild and its app icon set.
# Usage: scripts/check-app-build.sh path/to/Runnir.app BUNDLE_ID BUILD ICON_SET
if [ $# -ne 4 ]; then
    echo "usage: $0 APP BUNDLE_ID BUILD ICON_SET" >&2
    exit 2
fi
plist="$1/Contents/Info.plist"

check() {
    actual=$(/usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || echo "(missing)")
    if [ "$actual" != "$2" ]; then
        echo "$1 is $actual, expected $2" >&2
        exit 1
    fi
    echo "$1: $actual"
}

check CFBundleIdentifier "$2"
check RunnirBuild "$3"
check CFBundleIconName "$4"
