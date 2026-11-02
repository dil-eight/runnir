#!/bin/sh
set -eu

# Prints the SHA-1 of the Developer ID Application identity that signs
# Runnir (B48): SIGNING_IDENTITY when set, otherwise the one valid identity
# of the team APPLE_TEAM_ID in the keychain search list. codesign is given
# the SHA-1, so two certificates with one name never mix.
# Usage: scripts/signing-identity.sh
if [ -z "${APPLE_TEAM_ID:-}" ]; then
    echo "APPLE_TEAM_ID is not set: export the Apple Developer team ID (it is never written into the repository)" >&2
    exit 1
fi

# find-identity lines read `  1) <SHA-1> "Developer ID Application: <name> (<team>)"`.
identities=$(security find-identity -v -p codesigning |
    grep -F '"Developer ID Application: ' | grep -F "($APPLE_TEAM_ID)\"" | awk '{ print $2 }')

# The expiry date of the Developer ID certificate whose SHA-1 is $1.
expiry() {
    security find-certificate -a -Z -p -c "Developer ID Application: " |
        awk -v sha="$1" '
            /^SHA-1 hash:/ { take = ($3 == sha); next }
            take && /-----BEGIN CERTIFICATE-----/ { pem = 1 }
            pem { print }
            /-----END CERTIFICATE-----/ { pem = 0; take = 0 }' |
        openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//'
}

if [ -n "${SIGNING_IDENTITY:-}" ]; then
    wanted=$(printf '%s' "$SIGNING_IDENTITY" | tr '[:lower:]' '[:upper:]')
    if printf '%s\n' "$identities" | grep -qxF "$wanted"; then
        echo "$wanted"
        exit 0
    fi
    echo "SIGNING_IDENTITY $wanted is not a valid Developer ID Application identity of team $APPLE_TEAM_ID" >&2
    exit 1
fi

count=$(printf '%s' "$identities" | grep -c . || true)
case $count in
    0)
        echo "No valid Developer ID Application identity of team $APPLE_TEAM_ID in the keychain search list" >&2
        exit 1
        ;;
    1)
        echo "$identities"
        ;;
    *)
        echo "Several valid Developer ID Application identities of team $APPLE_TEAM_ID; set SIGNING_IDENTITY to one SHA-1 or remove the old certificate:" >&2
        printf '%s\n' "$identities" | while IFS= read -r sha; do
            expires=$(expiry "$sha")
            echo "  $sha  valid until ${expires:-unknown}" >&2
        done
        exit 1
        ;;
esac
