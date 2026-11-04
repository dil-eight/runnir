#!/bin/sh
set -eu

# Checks that a Developer ID provisioning profile fits an app (B48): it is
# for the bundle identifier BUNDLE, of the team APPLE_TEAM_ID when that is
# set, unexpired, and lists the certificate of IDENTITY (a SHA-1) when given.
# Prints the profile's application identifier. embed-profile.sh runs it
# before it embeds a profile, and the release workflow before it builds, so
# a profile made with another certificate fails a tag in its first minute.
# Usage: scripts/check-profile.sh PROFILE BUNDLE [IDENTITY]
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "usage: $0 PROFILE BUNDLE [IDENTITY]" >&2
    exit 2
fi
profile=$1 bundle=$2 identity=${3:-}
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
echo "$application"
