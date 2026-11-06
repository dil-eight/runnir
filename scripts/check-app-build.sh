#!/bin/sh
set -eu

# Checks that a built Runnir.app is the build it was meant to be (B47): its
# bundle ID, its RunnirBuild and its app icon set; and that it carries the
# license notices (B49).
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

licenses="$1/Contents/Resources/Licenses"
for file in notices.json Runnir-LICENSE.txt; do
    if [ ! -s "$licenses/$file" ]; then
        echo "Licenses/$file is missing" >&2
        exit 1
    fi
done
for group in "Runnir.app" "Runnir Core" "act"; do
    if ! plutil -extract groups json -o - "$licenses/notices.json" | grep -q "\"name\":\"$group\""; then
        echo "Licenses/notices.json has no group $group" >&2
        exit 1
    fi
done
echo "Licenses: notices.json, Runnir-LICENSE.txt"
