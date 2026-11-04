#!/bin/sh
set -eu

# Signs what is inside a built Runnir.app, inside out (B48): every library
# and framework in Contents/Frameworks, the helpers with their own
# identifiers, and a test bundle Xcode put into Contents/PlugIns. The caller
# signs the app itself last, with its entitlements. sign-app.sh and
# sign-dev-build.sh both use it, so every build signs the same code the same
# way; CODESIGN_ARG... (the identity and the options) go to each codesign.
# Usage: scripts/sign-contents.sh APP CODESIGN_ARG...
if [ $# -lt 2 ]; then
    echo "usage: $0 APP CODESIGN_ARG..." >&2
    exit 2
fi
app=$1
shift
if [ ! -f "$app/Contents/Info.plist" ]; then
    echo "$app is not an app bundle" >&2
    exit 1
fi

if [ -d "$app/Contents/Frameworks" ]; then
    find "$app/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) |
        while IFS= read -r library; do
            codesign --force "$@" "$library"
        done
fi
for helper in runnir-core:com.runnir.core act:com.runnir.act; do
    file=$app/Contents/Helpers/${helper%%:*}
    if [ -f "$file" ]; then
        codesign --force "$@" --identifier "${helper#*:}" "$file"
    fi
done
if [ -d "$app/Contents/PlugIns" ]; then
    find "$app/Contents/PlugIns" -maxdepth 1 -name '*.xctest' |
        while IFS= read -r bundle; do
            codesign --force "$@" "$bundle"
        done
fi
