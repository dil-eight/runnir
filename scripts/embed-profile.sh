#!/bin/sh
set -eu

# Embeds a Developer ID provisioning profile in a built Runnir.app and writes
# the entitlements its signature takes (B48): Runnir.entitlements with the
# app's application identifier and team, which the profile authorizes, and
# the profile's keychain access groups narrowed to the app's own. With them
# Runnir keeps its Keychain items in the data protection keychain, where the
# app's identifier and team decide access, not a list of programs on each
# item, so macOS never asks for the login password item by item. The team
# comes from the profile, never from the repository.
#
# The profile must be for the app's bundle identifier, unexpired, list the
# certificate of IDENTITY (a SHA-1) when given, and be of APPLE_TEAM_ID when
# that is set.
# Usage: scripts/embed-profile.sh APP PROFILE ENTITLEMENTS_OUT [IDENTITY]
if [ $# -lt 3 ] || [ $# -gt 4 ]; then
    echo "usage: $0 APP PROFILE ENTITLEMENTS_OUT [IDENTITY]" >&2
    exit 2
fi
app=$1 profile=$2 out=$3 identity=${4:-}
here=$(dirname "$0")
if [ ! -f "$app/Contents/Info.plist" ]; then
    echo "$app is not an app bundle" >&2
    exit 1
fi
if [ ! -f "$profile" ]; then
    echo "No provisioning profile at $profile: download the Developer ID profile of the app's App ID from developer.apple.com" >&2
    exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if ! security cms -D -i "$profile" -o "$work/profile.plist" 2>/dev/null || [ ! -s "$work/profile.plist" ]; then
    echo "$profile is not a provisioning profile" >&2
    exit 1
fi

field() { /usr/libexec/PlistBuddy -c "Print :$1" "$work/profile.plist" 2>/dev/null || true; }
application=$(field Entitlements:com.apple.application-identifier)
team=$(field TeamIdentifier:0)
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
if [ -z "$team" ] || [ "$application" != "$team.$bundle" ]; then
    echo "$profile is for ${application:-no application identifier}, not $bundle" >&2
    exit 1
fi
if [ -n "${APPLE_TEAM_ID:-}" ] && [ "$team" != "$APPLE_TEAM_ID" ]; then
    echo "$profile is of team $team, not $APPLE_TEAM_ID" >&2
    exit 1
fi
expires=$(plutil -extract ExpirationDate raw -o - "$work/profile.plist" 2>/dev/null || true)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ -z "$expires" ] || awk -v a="$expires" -v b="$now" 'BEGIN { exit !(a < b) }'; then
    echo "$profile expired ${expires:-at an unknown date}: download it again from developer.apple.com" >&2
    exit 1
fi
if [ -n "$identity" ]; then
    wanted=$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')
    count=$(plutil -extract DeveloperCertificates raw -o - "$work/profile.plist" 2>/dev/null || echo 0)
    found=no i=0
    while [ "$i" -lt "$count" ]; do
        sha=$(plutil -extract "DeveloperCertificates.$i" raw -o - "$work/profile.plist" | base64 -D | shasum -a 1 | awk '{ print toupper($1) }')
        if [ "$sha" = "$wanted" ]; then found=yes; fi
        i=$((i + 1))
    done
    if [ "$found" = no ]; then
        echo "$profile does not list the certificate $wanted: make the profile with that certificate" >&2
        exit 1
    fi
fi

cp "$here/../apps/macos/Runnir/Runnir.entitlements" "$out"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $application" \
    -c "Add :com.apple.developer.team-identifier string $team" "$out" >/dev/null
# The profile allows its team's groups (TEAM.*); the app takes its own.
if [ -n "$(field Entitlements:keychain-access-groups)" ]; then
    /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" \
        -c "Add :keychain-access-groups:0 string $application" "$out" >/dev/null
fi
cp "$profile" "$app/Contents/embedded.provisionprofile"
