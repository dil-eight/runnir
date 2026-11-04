#!/bin/sh
set -eu

# Sends a zip to Apple's notary service and waits for its verdict, at most
# 60 minutes (B48). Credentials: NOTARY_PROFILE, a notarytool keychain
# profile (on a Mac), or NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER_ID,
# an App Store Connect API key (in CI). Anything but Accepted prints Apple's
# log of the submission and fails.
# Usage: scripts/notarize.sh FILE
if [ $# -ne 1 ]; then
    echo "usage: $0 FILE" >&2
    exit 2
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    set -- "$1" --keychain-profile "$NOTARY_PROFILE"
else
    missing=""
    [ -n "${NOTARY_KEY_FILE:-}" ] || missing="$missing NOTARY_KEY_FILE"
    [ -n "${NOTARY_KEY_ID:-}" ] || missing="$missing NOTARY_KEY_ID"
    [ -n "${NOTARY_ISSUER_ID:-}" ] || missing="$missing NOTARY_ISSUER_ID"
    if [ -n "$missing" ]; then
        echo "No notarization credentials: set NOTARY_PROFILE, or NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER_ID. Missing:$missing" >&2
        exit 1
    fi
    if [ ! -f "$NOTARY_KEY_FILE" ]; then
        echo "NOTARY_KEY_FILE $NOTARY_KEY_FILE does not exist" >&2
        exit 1
    fi
    set -- "$1" --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
fi
# From here "$@" holds only the credentials.
file=$1
shift
if [ ! -f "$file" ]; then
    echo "$file does not exist" >&2
    exit 1
fi

result=$(mktemp)
trap 'rm -f "$result"' EXIT
# The verdict is read from the JSON, whatever notarytool's exit status.
xcrun notarytool submit "$file" "$@" --wait --timeout 60m --output-format json > "$result" || true
id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
status=$(plutil -extract status raw -o - "$result" 2>/dev/null || true)
echo "Notarization of $file: ${status:-no answer} (submission ${id:-none})"
if [ "$status" != Accepted ]; then
    if [ "$status" = "In Progress" ]; then
        # Apple goes on with it: wait for this submission instead of sending another.
        echo "No verdict within 60 minutes: run xcrun notarytool wait $id with the same credentials, then staple" >&2
    elif [ -n "$id" ]; then
        xcrun notarytool log "$id" "$@" >&2 || true
    fi
    exit 1
fi
