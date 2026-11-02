#!/bin/sh
set -eu

# Signs a built Runnir.app with Developer ID, inside out (B48, ADR 0005): the
# libraries in Contents/Frameworks, the helpers runnir-core and act, then the
# app with Runnir.entitlements (no App Sandbox, no exceptions). Every
# signature has the hardened runtime and a secure timestamp.
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

if [ -d "$app/Contents/Frameworks" ]; then
    find "$app/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) |
        while IFS= read -r library; do
            codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$library"
        done
fi
"$here/sign-binary.sh" "$app/Contents/Helpers/runnir-core" io.dil8.runnir.core
"$here/sign-binary.sh" "$app/Contents/Helpers/act" io.dil8.runnir.act
codesign --force --options runtime --timestamp \
    --entitlements "$here/../apps/macos/Runnir/Runnir.entitlements" \
    --sign "$SIGNING_IDENTITY" "$app"
"$here/check-signature.sh" "$app"
