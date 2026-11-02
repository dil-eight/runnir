#!/bin/sh
set -eu

# Checks the signing scripts' refusals (B48) with a stand-in for
# security(1). The signing itself needs a Developer ID identity and is
# checked on a Mac and by the first tag.
# Usage: scripts/test-signing.sh
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

# Made-up team IDs and SHA-1s: real ones never go into the repository.
team=TEAM000001
one=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
two=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
other=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
dev=DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD

# The stand-in answers find-identity with $tmp/identities and prints
# nothing for anything else, so no certificate has a known expiry date.
mkdir "$tmp/bin"
cat > "$tmp/bin/security" <<EOF
#!/bin/sh
if [ "\$1" = find-identity ]; then cat "$tmp/identities"; fi
EOF
chmod +x "$tmp/bin/security"
unset APPLE_TEAM_ID SIGNING_IDENTITY NOTARY_PROFILE NOTARY_KEY_FILE NOTARY_KEY_ID NOTARY_ISSUER_ID
PATH="$tmp/bin:$PATH"
export PATH

# identities SHA1:TEAM...: the valid Developer ID Application identities
# the stand-in lists, after which it lists an Apple Development one ($dev).
identities() {
    : > "$tmp/identities"
    n=0
    for entry in "$@"; do
        n=$((n + 1))
        printf '  %s) %s "Developer ID Application: Example (%s)"\n' "$n" "${entry%%:*}" "${entry#*:}" >> "$tmp/identities"
    done
    printf '  %s) %s "Apple Development: Example (%s)"\n' "$((n + 1))" "$dev" "$team" >> "$tmp/identities"
    printf '     %s valid identities found\n' "$((n + 1))" >> "$tmp/identities"
}

# check NAME STATUS TEXT COMMAND...: COMMAND exits with STATUS, and its
# output is exactly TEXT when STATUS is 0 or contains TEXT otherwise.
check() {
    name=$1 status=$2 text=$3
    shift 3
    set +e
    output=$("$@" 2>&1)
    actual=$?
    set -e
    passed=no
    if [ "$actual" -eq "$status" ]; then
        if [ "$status" -eq 0 ]; then
            if [ "$output" = "$text" ]; then passed=yes; fi
        else
            case $output in
                *"$text"*) passed=yes ;;
            esac
        fi
    fi
    if [ "$passed" = yes ]; then
        echo "ok      $name"
    else
        echo "FAILED  $name: exit $actual, expected $status with \"$text\"" >&2
        printf '%s\n' "$output" | sed 's/^/        /' >&2
        failures=$((failures + 1))
    fi
}

# signing-identity.sh
identities "$one:$team"
check "identity: no APPLE_TEAM_ID" 1 "APPLE_TEAM_ID is not set" \
    "$here/signing-identity.sh"
identities "$other:OTHER00001"
check "identity: none of the team" 1 "No valid Developer ID Application identity of team $team" \
    env APPLE_TEAM_ID=$team "$here/signing-identity.sh"
identities "$one:$team" "$other:OTHER00001"
check "identity: the one of the team" 0 "$one" \
    env APPLE_TEAM_ID=$team "$here/signing-identity.sh"
identities "$one:$team" "$two:$team"
check "identity: several of the team" 1 "Several valid Developer ID Application identities of team $team; set SIGNING_IDENTITY" \
    env APPLE_TEAM_ID=$team "$here/signing-identity.sh"
check "identity: several are listed" 1 "$two  valid until unknown" \
    env APPLE_TEAM_ID=$team "$here/signing-identity.sh"
check "identity: SIGNING_IDENTITY picks one" 0 "$two" \
    env APPLE_TEAM_ID=$team SIGNING_IDENTITY=$two "$here/signing-identity.sh"
check "identity: SIGNING_IDENTITY in lower case" 0 "$two" \
    env APPLE_TEAM_ID=$team SIGNING_IDENTITY="$(printf '%s' "$two" | tr '[:upper:]' '[:lower:]')" "$here/signing-identity.sh"
check "identity: SIGNING_IDENTITY of an Apple Development certificate" 1 "SIGNING_IDENTITY $dev is not a valid Developer ID Application identity of team $team" \
    env APPLE_TEAM_ID=$team SIGNING_IDENTITY=$dev "$here/signing-identity.sh"

# check-signature.sh, on a copy of true(1) signed ad hoc and one unsigned
cp /usr/bin/true "$tmp/adhoc"
codesign --force --options runtime --sign - "$tmp/adhoc" 2>/dev/null
cp /usr/bin/true "$tmp/unsigned"
codesign --remove-signature "$tmp/unsigned"
check "signature: no APPLE_TEAM_ID" 1 "APPLE_TEAM_ID is not set" \
    "$here/check-signature.sh" "$tmp/adhoc"
check "signature: unsigned" 1 "code object is not signed at all" \
    env APPLE_TEAM_ID=$team "$here/check-signature.sh" "$tmp/unsigned"
check "signature: ad hoc, without a team" 1 "TeamIdentifier is not set, expected $team" \
    env APPLE_TEAM_ID=$team "$here/check-signature.sh" "$tmp/adhoc"

# Summary
if [ "$failures" -ne 0 ]; then
    echo "$failures signing script checks failed" >&2
    exit 1
fi
echo "All signing script checks passed"
