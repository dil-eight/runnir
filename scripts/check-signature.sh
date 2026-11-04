#!/bin/sh
set -eu

# Checks that each file or bundle has a valid signature of the team
# APPLE_TEAM_ID, with the hardened runtime and a secure timestamp (B48). An
# app also has to embed its provisioning profile and carry the application
# identifier of its bundle identifier, for the data protection keychain.
# Usage: scripts/check-signature.sh CODE...
if [ $# -eq 0 ]; then
    echo "usage: $0 CODE..." >&2
    exit 2
fi
if [ -z "${APPLE_TEAM_ID:-}" ]; then
    echo "APPLE_TEAM_ID is not set: export the Apple Developer team ID (it is never written into the repository)" >&2
    exit 1
fi

for code in "$@"; do
    codesign --verify --deep --strict "$code"
    details=$(codesign --display --verbose=2 "$code" 2>&1)
    team=$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')
    if [ "$team" != "$APPLE_TEAM_ID" ]; then
        echo "$code: TeamIdentifier is ${team:-missing}, expected $APPLE_TEAM_ID" >&2
        exit 1
    fi
    if ! printf '%s\n' "$details" | grep -q '^CodeDirectory .*flags=.*runtime'; then
        echo "$code: no hardened runtime" >&2
        exit 1
    fi
    if ! printf '%s\n' "$details" | grep -q '^Timestamp='; then
        echo "$code: no secure timestamp" >&2
        exit 1
    fi
    if [ -f "$code/Contents/Info.plist" ]; then
        bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$code/Contents/Info.plist")
        if [ ! -f "$code/Contents/embedded.provisionprofile" ]; then
            echo "$code: no embedded provisioning profile" >&2
            exit 1
        fi
        entitlements=$(mktemp)
        codesign --display --entitlements - --xml "$code" > "$entitlements" 2>/dev/null || true
        application=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$entitlements" 2>/dev/null || true)
        rm -f "$entitlements"
        if [ "$application" != "$APPLE_TEAM_ID.$bundle" ]; then
            echo "$code: application identifier is ${application:-missing}, expected $APPLE_TEAM_ID.$bundle" >&2
            exit 1
        fi
        echo "$code: team $team, hardened runtime, timestamp, application identifier"
    else
        echo "$code: team $team, hardened runtime, timestamp"
    fi
done
