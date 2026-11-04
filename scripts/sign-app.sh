#!/bin/sh
set -eu

# Signs a built Runnir.app with Developer ID, inside out (B48, ADR 0005): the
# libraries in Contents/Frameworks, the helpers runnir-core and act, then the
# app with Runnir.entitlements (no App Sandbox, no exceptions) and the
# application identifier of its provisioning profile, which embed-profile.sh
# puts into the app, so it keeps its Keychain items in the data protection
# keychain. Every signature has the hardened runtime and a secure timestamp.
#
# The profile is RUNNIR_PROFILE, else ~/.config/runnir/release.provisionprofile
# for com.runnir.app and local.provisionprofile for com.runnir.app.local.
# Usage: scripts/sign-app.sh path/to/Runnir.app
if [ $# -ne 1 ]; then
    echo "usage: $0 APP" >&2
    exit 2
fi
app=$1
if [ ! -f "$app/Contents/Info.plist" ]; then
    echo "$app is not an app bundle" >&2
    exit 1
fi
here=$(dirname "$0")
# Chosen once, so the helpers are signed with the same identity as the app.
SIGNING_IDENTITY=$("$here/signing-identity.sh")
export SIGNING_IDENTITY
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
case $bundle in
    com.runnir.app) name=release ;;
    com.runnir.app.*) name=${bundle#com.runnir.app.} ;;
    *) name=$bundle ;;
esac
profile=${RUNNIR_PROFILE:-$HOME/.config/runnir/$name.provisionprofile}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$here/embed-profile.sh" "$app" "$profile" "$work/entitlements.plist" "$SIGNING_IDENTITY"

if [ -d "$app/Contents/Frameworks" ]; then
    find "$app/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) |
        while IFS= read -r library; do
            codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$library"
        done
fi
"$here/sign-binary.sh" "$app/Contents/Helpers/runnir-core" com.runnir.core
"$here/sign-binary.sh" "$app/Contents/Helpers/act" com.runnir.act
codesign --force --options runtime --timestamp \
    --entitlements "$work/entitlements.plist" \
    --sign "$SIGNING_IDENTITY" "$app"
"$here/check-signature.sh" "$app"
