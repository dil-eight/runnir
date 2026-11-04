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
# The profile must fit the app (check-profile.sh): for its bundle
# identifier, unexpired, listing the certificate of IDENTITY (a SHA-1) when
# given, and of APPLE_TEAM_ID when that is set.
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
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
application=$("$here/check-profile.sh" "$profile" "$bundle" "$identity")
team=${application%%.*}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
security cms -D -i "$profile" -o "$work/profile.plist" 2>/dev/null

# entitle KEY TYPE [VALUE]: the key as given, whatever Runnir.entitlements
# already says about it.
entitle() {
    /usr/libexec/PlistBuddy -c "Delete :$1" "$out" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$1 $2${3:+ $3}" "$out" >/dev/null
}
cp "$here/../apps/macos/Runnir/Runnir.entitlements" "$out"
entitle com.apple.application-identifier string "$application"
entitle com.apple.developer.team-identifier string "$team"
# The profile allows its team's groups (TEAM.*); the app takes its own.
if /usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups" "$work/profile.plist" >/dev/null 2>&1; then
    entitle keychain-access-groups array
    /usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string $application" "$out" >/dev/null
fi
cp "$profile" "$app/Contents/embedded.provisionprofile"
