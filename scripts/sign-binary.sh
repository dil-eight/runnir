#!/bin/sh
set -eu

# Signs one command-line binary with Developer ID, the hardened runtime and a
# secure timestamp, then checks the signature (B48).
# Usage: scripts/sign-binary.sh FILE IDENTIFIER
if [ $# -ne 2 ]; then
    echo "usage: $0 FILE IDENTIFIER" >&2
    exit 2
fi
if [ ! -f "$1" ]; then
    echo "$1 does not exist" >&2
    exit 1
fi
here=$(dirname "$0")
identity=$("$here/signing-identity.sh")
codesign --force --options runtime --timestamp --identifier "$2" --sign "$identity" "$1"
"$here/check-signature.sh" "$1"
