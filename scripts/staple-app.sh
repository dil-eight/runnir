#!/bin/sh
set -eu

# Staples the notarization ticket to a notarized Runnir.app and checks that
# Gatekeeper accepts it as notarized Developer ID software (B48).
# Usage: scripts/staple-app.sh path/to/Runnir.app
if [ $# -ne 1 ]; then
    echo "usage: $0 APP" >&2
    exit 2
fi
app=$1
if [ ! -f "$app/Contents/Info.plist" ]; then
    echo "$app is not an app bundle" >&2
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
# spctl writes its verdict to standard error.
if ! assessment=$(spctl --assess --type execute --verbose=2 "$app" 2>&1); then
    echo "$assessment" >&2
    exit 1
fi
echo "$assessment"
case $assessment in
    *"source=Notarized Developer ID"*) ;;
    *)
        echo "$app is not accepted as notarized Developer ID software" >&2
        exit 1
        ;;
esac
