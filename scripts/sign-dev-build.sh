#!/bin/sh
set -eu

# Signs a dev build (RUNNIR_BUILD=dev, Xcode's own builds) with the
# developer's own certificate (B48). An ad hoc signature names a build by its
# hash, which changes with every build, so Keychain took each one for another
# app and asked for the login password again; a certificate's signature names
# Runnir Dev by its identifier and certificate, and "Always Allow" holds
# across builds. The bundle identifier also becomes the signing identifier,
# so macOS lets the build post notifications.
#
# The SHA-1 of a code signing identity in the keychain search list comes from
# RUNNIR_DEV_SIGNING_IDENTITY or the first line of
# ~/.config/runnir/dev-signing-identity, never from the repository. Without
# either the build keeps the linker's ad hoc signature, as in CI. No hardened
# runtime and no timestamp: the unit tests load into the app, the debugger
# attaches to it, and a build needs no network.
#
# With the Developer ID provisioning profile of com.runnir.dev in
# RUNNIR_DEV_PROFILE or ~/.config/runnir/dev.provisionprofile, the build
# embeds it and takes its application identifier (embed-profile.sh), so it
# keeps its Keychain items in the data protection keychain and Keychain
# never asks for the password; get-task-allow keeps the unit tests and the
# debugger working. Without one, or with one that does not fit, the build
# uses the file-based keychain.
#
# The Runnir target's last build phase runs it on the built app.
# Usage: RUNNIR_BUILD=dev scripts/sign-dev-build.sh [APP]
app=${1:-${TARGET_BUILD_DIR:-}/${WRAPPER_NAME:-}}
here=$(dirname "$0")
# Local and tagged builds are signed by sign-app.sh.
if [ "${RUNNIR_BUILD:-}" != dev ]; then
    exit 0
fi
identity=${RUNNIR_DEV_SIGNING_IDENTITY:-}
file=${RUNNIR_DEV_SIGNING_FILE:-$HOME/.config/runnir/dev-signing-identity}
if [ -z "$identity" ] && [ -f "$file" ]; then
    identity=$(sed -n 1p "$file" | tr -d '[:space:]')
fi
if [ -z "$identity" ]; then
    exit 0
fi
identity=$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')
if ! security find-identity -v -p codesigning | awk '{ print $2 }' | grep -qxF "$identity"; then
    echo "warning: the dev signing identity $identity is not a valid code signing identity in the keychain search list; the build stays signed ad hoc"
    exit 0
fi
if [ ! -f "$app/Contents/Info.plist" ]; then
    echo "$app is not an app bundle" >&2
    exit 1
fi

sign() {
    codesign --force --timestamp=none --sign "$identity" "$@"
}

profile=${RUNNIR_DEV_PROFILE:-$HOME/.config/runnir/dev.provisionprofile}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
entitlements=
rm -f "$app/Contents/embedded.provisionprofile"
if [ -f "$profile" ]; then
    if "$here/embed-profile.sh" "$app" "$profile" "$work/entitlements.plist" "$identity" 2>"$work/error"; then
        entitlements=$work/entitlements.plist
        # The profile's entitlements make macOS guard the process; this one,
        # as in Xcode's development signing, still lets the unit tests be
        # injected and the debugger attach. Never in a signed release.
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$entitlements" >/dev/null
    else
        echo "warning: $(cat "$work/error"); the build uses the file-based keychain"
    fi
fi

# Inside out: libraries, the helpers, a test bundle Xcode put into the app,
# then the app.
if [ -d "$app/Contents/Frameworks" ]; then
    find "$app/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) |
        while IFS= read -r library; do
            sign "$library"
        done
fi
if [ -f "$app/Contents/Helpers/runnir-core" ]; then
    sign --identifier com.runnir.core "$app/Contents/Helpers/runnir-core"
fi
if [ -f "$app/Contents/Helpers/act" ]; then
    sign --identifier com.runnir.act "$app/Contents/Helpers/act"
fi
if [ -d "$app/Contents/PlugIns" ]; then
    find "$app/Contents/PlugIns" -maxdepth 1 -name '*.xctest' |
        while IFS= read -r bundle; do
            sign "$bundle"
        done
fi
if [ -n "$entitlements" ]; then
    sign --entitlements "$entitlements" "$app"
else
    sign "$app"
fi
