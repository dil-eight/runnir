# Signing and Notarization (B48) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every tagged build (release, alpha, beta) of Runnir.app and the macOS Core binaries is signed with Developer ID, notarized by Apple and published as `Runnir-<tag>.zip`, by scripts that run the same on a Mac and in the release workflow.

**Architecture:** Small POSIX `sh` scripts in `scripts/` do the work after the unsigned archive is built: `signing-identity.sh` picks the identity, `check-signature.sh` checks a signature, `sign-binary.sh` and `sign-app.sh` sign inside out, `notarize.sh` and `staple-app.sh` notarize and staple. `scripts/test-signing.sh` checks their refusals with a stand-in for `security(1)` and runs in CI. `release.yml` runs in the GitHub environment `release`, builds a temporary keychain from the secrets, calls the scripts and cleans up whatever happened.

**Tech Stack:** POSIX sh, macOS `codesign`, `security`, `xcrun notarytool` and `stapler`, `spctl`, `plutil`, `openssl` (LibreSSL), `ditto`, `zip`; GitHub Actions; `shellcheck` and actionlint for linting.

**Spec:** `docs/superpowers/specs/2026-11-01-signing-notarization-design.md`. **Branch:** `dilbarov/signing` (cut from `dilbarov/build-marks`, PR #56).

## Global Constraints

- The Team ID never goes into the repository: scripts read `APPLE_TEAM_ID` from the environment (the GitHub variable `APPLE_TEAM_ID` of the `release` environment in CI). No real team ID, certificate SHA-1 or team name in scripts, tests, docs or this plan; tests use made-up values.
- Every signature uses `--options runtime` (hardened runtime) and `--timestamp`.
- Identifiers: helpers `io.dil8.runnir.core` and `io.dil8.runnir.act`, Core CLI binaries `io.dil8.runnir.cli`. The app keeps its bundle ID (`io.dil8.runnir` for release, alpha and beta).
- `apps/macos/Runnir/Runnir.entitlements` stays empty (no App Sandbox, no exceptions, ADR 0005); the helpers get no entitlements.
- The Xcode project's signing settings do not change (`CODE_SIGNING_ALLOWED = NO` stays); `app-build.yml` does not change.
- Scripts are `#!/bin/sh` with `set -eu`, in the style of `scripts/check-app-build.sh`; only tools that ship with macOS and Xcode. No new dependencies.
- Notarization waits at most 60 minutes; the release job's limit is 90 minutes.
- A missing secret or `APPLE_TEAM_ID` fails the tag, naming what is missing. No unsigned build is published.
- The app asset is `Runnir-<tag>.zip` (no `-unsigned`).
- Do not claim signing or notarization complete until it is verified (AGENTS.md). The CI path is verified only by the first tag.
- Commits: no AI attribution of any kind (AGENTS.md). Stage files by path; `docs/design/runnir.pen` is not part of this work.

## Deviations from the spec, folded into its text in Task 6

- Two helper scripts beside the four: `signing-identity.sh` (the identity rule) and `check-signature.sh` (team, hardened runtime, timestamp), shared by `sign-binary.sh` and `sign-app.sh`.
- `scripts/test-signing.sh` checks the refusals and runs as a step of `ci.yml`'s build job.
- `release.yml` picks the build first (a bad tag fails before any work), and its keychain step also imports Apple's Developer ID G2 intermediate, so the chain is complete whatever the runner image holds.

---

### Task 1: The identity and the signature check

**Files:**
- Create: `scripts/signing-identity.sh`
- Create: `scripts/check-signature.sh`
- Create: `scripts/test-signing.sh`
- Modify: `.github/workflows/ci.yml` (a step in `build-test-analyze`)

**Interfaces:**
- Produces: `scripts/signing-identity.sh` prints one upper-case SHA-1 on standard output, or exits 1 with a message on standard error. Reads `APPLE_TEAM_ID` (required) and `SIGNING_IDENTITY` (optional).
- Produces: `scripts/check-signature.sh CODE...` exits 0 and prints `<CODE>: team <T>, hardened runtime, timestamp` for each, or exits 1 naming the first problem. Reads `APPLE_TEAM_ID`.
- Produces: `scripts/test-signing.sh` with a `check NAME STATUS TEXT COMMAND...` function and an `identities SHA1:TEAM...` fixture function; later tasks add checks above its `# Summary` line.

- [ ] **Step 1: Write the failing tests**

Create `scripts/test-signing.sh`:

```sh
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
```

Then: `chmod +x scripts/test-signing.sh`

- [ ] **Step 2: Run the tests to see them fail**

Run: `scripts/test-signing.sh`
Expected: exit 1; every check `FAILED` with `No such file or directory` (exit 127), last line `11 signing script checks failed`.

- [ ] **Step 3: Write `scripts/signing-identity.sh`**

```sh
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
```

Then: `chmod +x scripts/signing-identity.sh`

- [ ] **Step 4: Write `scripts/check-signature.sh`**

```sh
#!/bin/sh
set -eu

# Checks that each file or bundle has a valid signature of the team
# APPLE_TEAM_ID, with the hardened runtime and a secure timestamp (B48).
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
    echo "$code: team $team, hardened runtime, timestamp"
done
```

Then: `chmod +x scripts/check-signature.sh`

- [ ] **Step 5: Run the tests to see them pass**

Run: `scripts/test-signing.sh`
Expected: 11 lines starting `ok`, last line `All signing script checks passed`, exit 0.

- [ ] **Step 6: Run the tests in CI**

In `.github/workflows/ci.yml`, job `build-test-analyze`, insert between `Show Xcode version` and `Build`:

```yaml
      - name: Signing scripts
        # Their refusals; the signing itself is checked on a Mac and by a tag.
        run: scripts/test-signing.sh
```

- [ ] **Step 7: Lint**

Run: `command -v shellcheck || brew install shellcheck`, then `shellcheck scripts/signing-identity.sh scripts/check-signature.sh scripts/test-signing.sh`
Expected: no output, exit 0. Fix anything it reports in the scripts, then rerun Step 5.

Run: `cd core && go run github.com/rhysd/actionlint/cmd/actionlint ../.github/workflows/ci.yml`
Expected: no output, exit 0.

- [ ] **Step 8: Commit**

```bash
git add scripts/signing-identity.sh scripts/check-signature.sh scripts/test-signing.sh .github/workflows/ci.yml
git commit -m "Scripts: the signing identity and the signature check (B48)"
```

---

### Task 2: Signing a binary and the app

**Files:**
- Create: `scripts/sign-binary.sh`
- Create: `scripts/sign-app.sh`
- Modify: `scripts/test-signing.sh` (checks above `# Summary`)

**Interfaces:**
- Consumes: `scripts/signing-identity.sh` (prints the SHA-1 or exits 1), `scripts/check-signature.sh CODE...`, and in the tests `check` and `identities` from Task 1.
- Produces: `scripts/sign-binary.sh FILE IDENTIFIER` signs FILE in place and checks it; exit 1 with a message on failure.
- Produces: `scripts/sign-app.sh APP` signs `APP/Contents/Frameworks/*.dylib|*.framework`, `APP/Contents/Helpers/runnir-core` (`io.dil8.runnir.core`), `APP/Contents/Helpers/act` (`io.dil8.runnir.act`), then APP with `apps/macos/Runnir/Runnir.entitlements`, and checks APP.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-signing.sh`, insert above the `# Summary` line:

```sh
# sign-binary.sh and sign-app.sh
mkdir -p "$tmp/Fake.app/Contents"
touch "$tmp/Fake.app/Contents/Info.plist"
identities "$other:OTHER00001"
check "sign-binary: missing file" 1 "$tmp/missing does not exist" \
    env APPLE_TEAM_ID=$team "$here/sign-binary.sh" "$tmp/missing" io.dil8.runnir.cli
check "sign-binary: no identity of the team" 1 "No valid Developer ID Application identity of team $team" \
    env APPLE_TEAM_ID=$team "$here/sign-binary.sh" "$tmp/adhoc" io.dil8.runnir.cli
check "sign-app: not an app" 1 "$tmp is not an app bundle" \
    env APPLE_TEAM_ID=$team "$here/sign-app.sh" "$tmp"
check "sign-app: no APPLE_TEAM_ID" 1 "APPLE_TEAM_ID is not set" \
    "$here/sign-app.sh" "$tmp/Fake.app"
check "sign-app: no identity of the team" 1 "No valid Developer ID Application identity of team $team" \
    env APPLE_TEAM_ID=$team "$here/sign-app.sh" "$tmp/Fake.app"
identities "$one:$team" "$two:$team"
check "sign-app: several identities" 1 "set SIGNING_IDENTITY to one SHA-1" \
    env APPLE_TEAM_ID=$team "$here/sign-app.sh" "$tmp/Fake.app"
```

- [ ] **Step 2: Run the tests to see the new ones fail**

Run: `scripts/test-signing.sh`
Expected: the 11 checks of Task 1 `ok`; the 6 new ones `FAILED` (exit 127); last line `6 signing script checks failed`.

- [ ] **Step 3: Write `scripts/sign-binary.sh`**

```sh
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
```

Then: `chmod +x scripts/sign-binary.sh`

- [ ] **Step 4: Write `scripts/sign-app.sh`**

```sh
#!/bin/sh
set -eu

# Signs a built Runnir.app with Developer ID, inside out (B48, ADR 0005): the
# libraries in Contents/Frameworks, the helpers runnir-core and act, then the
# app with Runnir.entitlements (no App Sandbox, no exceptions). Every
# signature has the hardened runtime and a secure timestamp.
# Usage: scripts/sign-app.sh path/to/Runnir.app
if [ $# -ne 1 ]; then
    echo "usage: $0 APP" >&2
    exit 2
fi
app=$1
if [ ! -f "$app/Contents/Info.plist" ]; then
    echo "$app is not an app bundle" >&2
    exit 1
fi
here=$(dirname "$0")
# Chosen once, so the helpers are signed with the same identity as the app.
SIGNING_IDENTITY=$("$here/signing-identity.sh")
export SIGNING_IDENTITY

if [ -d "$app/Contents/Frameworks" ]; then
    find "$app/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) |
        while IFS= read -r library; do
            codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$library"
        done
fi
"$here/sign-binary.sh" "$app/Contents/Helpers/runnir-core" io.dil8.runnir.core
"$here/sign-binary.sh" "$app/Contents/Helpers/act" io.dil8.runnir.act
codesign --force --options runtime --timestamp \
    --entitlements "$here/../apps/macos/Runnir/Runnir.entitlements" \
    --sign "$SIGNING_IDENTITY" "$app"
"$here/check-signature.sh" "$app"
```

Then: `chmod +x scripts/sign-app.sh`

Today's app has one library in Frameworks (`libswiftCompatibilitySpan.dylib`) and Swift package resource bundles in Resources; the bundles hold no code and are sealed by the app's signature. Signing a copy of a Debug build ad hoc in this order passes `codesign --verify --deep --strict`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `scripts/test-signing.sh`
Expected: 17 lines starting `ok`, last line `All signing script checks passed`.

- [ ] **Step 6: Lint**

Run: `shellcheck scripts/sign-binary.sh scripts/sign-app.sh scripts/test-signing.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/sign-binary.sh scripts/sign-app.sh scripts/test-signing.sh
git commit -m "Scripts: sign a binary and the app inside out (B48)"
```

---

### Task 3: Notarizing and stapling

**Files:**
- Create: `scripts/notarize.sh`
- Create: `scripts/staple-app.sh`
- Modify: `scripts/test-signing.sh` (checks above `# Summary`)

**Interfaces:**
- Consumes: `check` from Task 1; the files `$tmp/adhoc` and `$tmp/Fake.app` the tests create in Tasks 1 and 2.
- Produces: `scripts/notarize.sh FILE` exits 0 after printing `Notarization of FILE: Accepted (submission <id>)`, or exits 1. Reads `NOTARY_PROFILE`, or `NOTARY_KEY_FILE`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`.
- Produces: `scripts/staple-app.sh APP` exits 0 after printing `spctl`'s assessment with `source=Notarized Developer ID`, or exits 1.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-signing.sh`, insert above the `# Summary` line:

```sh
# notarize.sh and staple-app.sh
touch "$tmp/key.p8"
check "notarize: no credentials" 1 "set NOTARY_PROFILE, or NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER_ID" \
    "$here/notarize.sh" "$tmp/adhoc"
check "notarize: a missing key ID is named" 1 "Missing: NOTARY_KEY_ID" \
    env NOTARY_KEY_FILE="$tmp/key.p8" NOTARY_ISSUER_ID=issuer "$here/notarize.sh" "$tmp/adhoc"
check "notarize: missing key file" 1 "NOTARY_KEY_FILE $tmp/missing.p8 does not exist" \
    env NOTARY_KEY_FILE="$tmp/missing.p8" NOTARY_KEY_ID=key NOTARY_ISSUER_ID=issuer "$here/notarize.sh" "$tmp/adhoc"
check "notarize: missing file" 1 "$tmp/missing.zip does not exist" \
    env NOTARY_PROFILE=profile "$here/notarize.sh" "$tmp/missing.zip"
check "staple: not an app" 1 "$tmp is not an app bundle" \
    "$here/staple-app.sh" "$tmp"
```

- [ ] **Step 2: Run the tests to see the new ones fail**

Run: `scripts/test-signing.sh`
Expected: 17 `ok`, the 5 new checks `FAILED` (exit 127), last line `5 signing script checks failed`.

- [ ] **Step 3: Write `scripts/notarize.sh`**

```sh
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
    if [ -n "$id" ]; then
        xcrun notarytool log "$id" "$@" >&2 || true
    fi
    exit 1
fi
```

Then: `chmod +x scripts/notarize.sh`

- [ ] **Step 4: Write `scripts/staple-app.sh`**

```sh
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
```

Then: `chmod +x scripts/staple-app.sh`

- [ ] **Step 5: Run the tests to see them pass**

Run: `scripts/test-signing.sh`
Expected: 22 lines starting `ok`, last line `All signing script checks passed`.

- [ ] **Step 6: Lint**

Run: `shellcheck scripts/*.sh`
Expected: no findings in the six signing scripts or `test-signing.sh`. Findings in older scripts (`build-core-macos.sh`, `generate-contracts.sh`, `measure-resources.sh`, `pain-tracker.sh`, `check-app-build.sh`) are out of scope; note them for the PR description.

- [ ] **Step 7: Commit**

```bash
git add scripts/notarize.sh scripts/staple-app.sh scripts/test-signing.sh
git commit -m "Scripts: notarize and staple (B48)"
```

---

### Task 4: The release workflow signs and notarizes

**Files:**
- Modify: `.github/workflows/release.yml` (whole file below)

**Interfaces:**
- Consumes: every script from Tasks 1 to 3 with the interfaces given there; `scripts/check-app-build.sh APP BUNDLE_ID BUILD ICON_SET` (B47).
- Consumes: the `release` environment: secrets `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`; variable `APPLE_TEAM_ID`; deployment rule for tags `v*` (all set up on 2026-11-02).

Secrets reach only the steps that need them, never the job's `env`: the archive step runs Swift package build plugins and the Go builds, which must not see them.

- [ ] **Step 1: Replace `.github/workflows/release.yml`**

```yaml
name: Release Build

# The only workflow that keeps build output: the tagged app and Core binaries
# are published as assets of a draft GitHub release. One job builds them all,
# so no Actions artifacts are needed to pass files between jobs. The app and
# the macOS Core binaries are signed with Developer ID and notarized (B48);
# the credentials live in the release environment, which only v* tags reach.
on:
  push:
    tags:
      - "v*.*.*"

permissions:
  contents: write

jobs:
  build-release:
    name: Build signed release
    runs-on: macos-26
    environment: release
    timeout-minutes: 90
    env:
      APPLE_TEAM_ID: ${{ vars.APPLE_TEAM_ID }}
      APP: build/Runnir.xcarchive/Products/Applications/Runnir.app
    steps:
      - uses: actions/checkout@v7

      - name: Pick the build
        # v1.2.3 is a release, v1.2.3-alpha.N an alpha and v1.2.3-beta.N a
        # beta (B47); any other tag stops here instead of shipping unmarked.
        run: |
          if [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            build=release icon=AppIcon
          elif [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$ ]]; then
            build=alpha icon=AppIcon-Alpha
          elif [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]]; then
            build=beta icon=AppIcon-Beta
          else
            echo "::error::Tag $GITHUB_REF_NAME is not vX.Y.Z, vX.Y.Z-alpha.N or vX.Y.Z-beta.N"
            exit 1
          fi
          echo "RUNNIR_BUILD=$build" >> "$GITHUB_ENV"
          echo "RUNNIR_ICON=$icon" >> "$GITHUB_ENV"

      - name: Check signing credentials
        # A tag without them fails here instead of publishing unsigned.
        env:
          DEVELOPER_ID_P12: ${{ secrets.DEVELOPER_ID_P12 }}
          DEVELOPER_ID_P12_PASSWORD: ${{ secrets.DEVELOPER_ID_P12_PASSWORD }}
          NOTARY_KEY_P8: ${{ secrets.NOTARY_KEY_P8 }}
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
        run: |
          missing=""
          for name in DEVELOPER_ID_P12 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID APPLE_TEAM_ID; do
            if [ -z "${!name}" ]; then missing="$missing $name"; fi
          done
          if [ -n "$missing" ]; then
            echo "::error::Missing in the release environment:$missing"
            exit 1
          fi

      - name: Set up the signing keychain
        # A temporary keychain holds the Developer ID certificate for codesign
        # only, with Apple's Developer ID G2 intermediate to complete its
        # chain; the notarization key goes to the job's temporary folder.
        env:
          DEVELOPER_ID_P12: ${{ secrets.DEVELOPER_ID_P12 }}
          DEVELOPER_ID_P12_PASSWORD: ${{ secrets.DEVELOPER_ID_P12_PASSWORD }}
          NOTARY_KEY_P8: ${{ secrets.NOTARY_KEY_P8 }}
        run: |
          umask 077
          keychain="$RUNNER_TEMP/signing.keychain-db"
          password=$(openssl rand -hex 24)
          echo "::add-mask::$password"
          security list-keychains -d user | sed 's/^ *"//; s/"$//' > "$RUNNER_TEMP/keychains.txt"
          security create-keychain -p "$password" "$keychain"
          security set-keychain-settings -lut 21600 "$keychain"
          security unlock-keychain -p "$password" "$keychain"
          printf '%s' "$DEVELOPER_ID_P12" | base64 --decode > "$RUNNER_TEMP/developer-id.p12"
          security import "$RUNNER_TEMP/developer-id.p12" -k "$keychain" -f pkcs12 \
            -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
          rm -f "$RUNNER_TEMP/developer-id.p12"
          curl -fsSL -o "$RUNNER_TEMP/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
          security import "$RUNNER_TEMP/DeveloperIDG2CA.cer" -k "$keychain"
          security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" > /dev/null
          set -- "$keychain"
          while IFS= read -r existing; do set -- "$@" "$existing"; done < "$RUNNER_TEMP/keychains.txt"
          security list-keychains -d user -s "$@"
          printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$RUNNER_TEMP/notary-key.p8"
          echo "NOTARY_KEY_FILE=$RUNNER_TEMP/notary-key.p8" >> "$GITHUB_ENV"
          scripts/signing-identity.sh > /dev/null

      - name: Select newest Xcode
        # Swift package dependencies (gRPC, SwiftNIO) need Swift 6.2 or newer.
        run: sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"

      - uses: actions/setup-go@v7
        with:
          go-version-file: core/go.mod
          cache: false

      - name: Build Core binaries
        working-directory: core
        env:
          CGO_ENABLED: "0"
        run: |
          for goos in darwin linux windows; do
            for goarch in arm64 amd64; do
              suffix=""
              if [ "$goos" = windows ]; then suffix=".exe"; fi
              GOOS=$goos GOARCH=$goarch go build -trimpath \
                -ldflags "-X runnir/core/internal/buildinfo.Version=${GITHUB_REF_NAME#v}" \
                -o "../build/export/runnir-${GITHUB_REF_NAME}-${goos}-${goarch}${suffix}" ./cmd/runnir
            done
          done

      - name: Sign and notarize Core binaries
        # The two darwin binaries go to Apple in one zip. A bare command-line
        # binary cannot carry a ticket, so macOS checks it online.
        env:
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
        run: |
          for goarch in arm64 amd64; do
            scripts/sign-binary.sh "build/export/runnir-${GITHUB_REF_NAME}-darwin-${goarch}" io.dil8.runnir.cli
          done
          zip -j "$RUNNER_TEMP/runnir-darwin.zip" build/export/runnir-"${GITHUB_REF_NAME}"-darwin-*
          scripts/notarize.sh "$RUNNER_TEMP/runnir-darwin.zip"

      - name: Build archive
        run: |
          xcodebuild archive \
            -project apps/macos/Runnir.xcodeproj \
            -scheme Runnir \
            -destination 'generic/platform=macOS' \
            -archivePath "$PWD/build/Runnir.xcarchive" \
            MARKETING_VERSION="${GITHUB_REF_NAME#v}" \
            RUNNIR_BUILD="$RUNNIR_BUILD" \
            CODE_SIGNING_ALLOWED=NO

      - name: Check the build
        run: scripts/check-app-build.sh "$APP" io.dil8.runnir "$RUNNIR_BUILD" "$RUNNIR_ICON"

      - name: Sign the app
        run: scripts/sign-app.sh "$APP"

      - name: Notarize and staple the app
        env:
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
        run: |
          ditto -c -k --keepParent "$APP" "$RUNNER_TEMP/Runnir-notarize.zip"
          scripts/notarize.sh "$RUNNER_TEMP/Runnir-notarize.zip"
          scripts/staple-app.sh "$APP"

      - name: Package app
        run: ditto -c -k --sequesterRsrc --keepParent "$APP" "build/export/Runnir-${GITHUB_REF_NAME}.zip"

      - name: Publish draft release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          prerelease_flag=""
          if [[ "${GITHUB_REF_NAME}" == *-* ]]; then
            prerelease_flag="--prerelease"
          fi

          gh release create "${GITHUB_REF_NAME}" \
            "build/export/Runnir-${GITHUB_REF_NAME}.zip" \
            build/export/runnir-* \
            --draft \
            ${prerelease_flag} \
            --title "Runnir ${GITHUB_REF_NAME}" \
            --notes "Runnir.app and the macOS command-line binaries are signed with Developer ID and notarized by Apple. The Linux and Windows binaries are not signed."

      - name: Check release assets
        # Downloads every asset back from the release and compares it with
        # the file that was built.
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          (cd build/export && shasum -a 256 Runnir-* runnir-*) > "$RUNNER_TEMP/built.sha256"
          gh release download "${GITHUB_REF_NAME}" --dir "$RUNNER_TEMP/downloaded"
          (cd "$RUNNER_TEMP/downloaded" && shasum -a 256 -c "$RUNNER_TEMP/built.sha256")
          test "$(ls "$RUNNER_TEMP/downloaded" | wc -l)" -eq "$(wc -l < "$RUNNER_TEMP/built.sha256")"

      - name: Clean up signing
        # Whatever happened before: the keychain search list as it was, the
        # temporary keychain and the key files gone.
        if: always()
        run: |
          if [ -s "$RUNNER_TEMP/keychains.txt" ]; then
            set --
            while IFS= read -r existing; do set -- "$@" "$existing"; done < "$RUNNER_TEMP/keychains.txt"
            security list-keychains -d user -s "$@"
          fi
          security delete-keychain "$RUNNER_TEMP/signing.keychain-db" 2>/dev/null || true
          rm -f "$RUNNER_TEMP/developer-id.p12" "$RUNNER_TEMP/notary-key.p8"
```

`${prerelease_flag}` stays unquoted on purpose, as before: when empty it must expand to no argument.

- [ ] **Step 2: Lint**

Run: `cd core && go run github.com/rhysd/actionlint/cmd/actionlint ../.github/workflows/release.yml ../.github/workflows/ci.yml`
Expected: no output, exit 0. With `shellcheck` installed, actionlint also checks every `run:` block. If it reports SC2086 on `${prerelease_flag}`, add `# shellcheck disable=SC2086` above the `gh release create` line and rerun.

- [ ] **Step 3: Check the parts that do not need the secrets**

Run each in a shell from the repository root:

```bash
for tag in v1.2.3 v1.2.3-alpha.1 v1.2.3-beta.2 v1.2.3-rc.1; do GITHUB_REF_NAME=$tag bash -c 'if [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$GITHUB_REF_NAME release"; elif [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$ ]]; then echo "$GITHUB_REF_NAME alpha"; elif [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]]; then echo "$GITHUB_REF_NAME beta"; else echo "$GITHUB_REF_NAME refused"; fi'; done
```

Expected: `v1.2.3 release`, `v1.2.3-alpha.1 alpha`, `v1.2.3-beta.2 beta`, `v1.2.3-rc.1 refused`.

```bash
env -i PATH="$PATH" bash -c 'DEVELOPER_ID_P12=x NOTARY_KEY_ID=y; missing=""; for name in DEVELOPER_ID_P12 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID APPLE_TEAM_ID; do if [ -z "${!name}" ]; then missing="$missing $name"; fi; done; echo "Missing:$missing"'
```

Expected: `Missing: DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_P8 NOTARY_ISSUER_ID APPLE_TEAM_ID`.

```bash
ca="$(mktemp -d)/DeveloperIDG2CA.cer" && curl -fsSL -o "$ca" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer && openssl x509 -inform DER -in "$ca" -noout -subject -enddate; rm -f "$ca"
```

Expected: a subject with `CN=Developer ID Certification Authority`, `OU=G2`, and a `notAfter` years ahead.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "CI: the release workflow signs and notarizes tagged builds (B48)"
```

---

### Task 5: The whole path on a Mac

No files change. This checks the scripts end to end with the Developer ID certificate in the login keychain and the `runnir-notary` profile, on a Release archive of a beta build. Write down what passed and the date: Task 6 states exactly that, no more.

The beta build is `io.dil8.runnir`, so it uses the release folders (`~/Library/Application Support/Runnir`, `~/Library/Logs/Runnir`) and Keychain items. Data from earlier development builds there may be discarded (AGENTS.md: no backward compatibility before the first release tag).

- [ ] **Step 1: Build and check a beta Release archive**

```bash
xcodebuild archive -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'generic/platform=macOS' -archivePath "$PWD/build/signing/Runnir.xcarchive" MARKETING_VERSION=0.0.0 RUNNIR_BUILD=beta CODE_SIGNING_ALLOWED=NO
```

```bash
scripts/check-app-build.sh build/signing/Runnir.xcarchive/Products/Applications/Runnir.app io.dil8.runnir beta AppIcon-Beta
```

Expected: `** ARCHIVE SUCCEEDED **`, then `CFBundleIdentifier: io.dil8.runnir`, `RunnirBuild: beta`, `CFBundleIconName: AppIcon-Beta`.

- [ ] **Step 2: Sign and check the app**

In one shell, with the team ID taken from the GitHub variable so it is typed nowhere:

```bash
export APPLE_TEAM_ID="$(gh variable get APPLE_TEAM_ID --env release --repo dil-eight/runnir)" NOTARY_PROFILE=runnir-notary APP=build/signing/Runnir.xcarchive/Products/Applications/Runnir.app
```

```bash
scripts/sign-app.sh "$APP"
```

Expected: `runnir-core`, `act` and the app each end with `: team <team ID>, hardened runtime, timestamp`, exit 0. If macOS asks whether codesign may use the key, the user answers Always Allow. With several valid identities the script stops and lists them; set `SIGNING_IDENTITY` to the newer one and rerun.

```bash
codesign --display --entitlements - "$APP"
```

Expected: no entitlement keys (an empty dict or nothing after the path).

- [ ] **Step 3: Notarize and staple the app**

```bash
ditto -c -k --keepParent "$APP" build/signing/Runnir-notarize.zip && scripts/notarize.sh build/signing/Runnir-notarize.zip
```

Expected: `Notarization of build/signing/Runnir-notarize.zip: Accepted (submission <id>)`. Apple's first submissions for a new team can take hours (the team's first test submission of 2026-11-01 waited more than three). If the script stops after 60 minutes with `In Progress`, wait with `xcrun notarytool wait <id> --keychain-profile runnir-notary` and go on once it says Accepted. Anything else: read the log the script printed, fix, and start again from Step 1.

```bash
scripts/staple-app.sh "$APP"
```

Expected: `The staple and validate action worked!`, then the assessment with `accepted`, `source=Notarized Developer ID` and `origin=Developer ID Application: …`.

- [ ] **Step 4: Sign and notarize a Core binary**

```bash
(cd core && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o ../build/signing/runnir-darwin-arm64 ./cmd/runnir)
```

```bash
scripts/sign-binary.sh build/signing/runnir-darwin-arm64 io.dil8.runnir.cli && zip -j build/signing/runnir-darwin.zip build/signing/runnir-darwin-arm64 && scripts/notarize.sh build/signing/runnir-darwin.zip
```

Expected: `build/signing/runnir-darwin-arm64: team <team ID>, hardened runtime, timestamp`, then `Accepted`.

- [ ] **Step 5: Open them as if downloaded**

Mark both as downloaded, then run the binary and open the app:

```bash
xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" build/signing/runnir-darwin-arm64 && build/signing/runnir-darwin-arm64 version
```

Expected: the version is printed; no "cannot be opened" dialog.

```bash
xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$APP" && open "$APP"
```

Expected: macOS says Runnir was downloaded from the internet and that Apple checked it for malicious software; Open starts it. No "cannot be opened" or "unidentified developer" dialog. The app icon and menu bar show BETA.

- [ ] **Step 6: The signed app works under the hardened runtime**

By hand, with the user, in the opened beta:

1. Sign in to GitHub (Device Flow). Quit with ⌘Q, open the app again: still signed in, no Keychain prompt.
2. Add a workspace for a folder with workflows (for example this repository): its workflow files are listed and open in the editor.
3. The Core runs from the signed bundle:

```bash
pgrep -fl 'Runnir.app/Contents/Helpers/runnir-core'
```

Expected: one process whose path is inside `build/signing/…/Runnir.app`.

4. Optional, when a container engine runs: Run Locally on a small workflow reaches the review and runs with act.

- [ ] **Step 7: Clean up**

Quit the beta. Remove `build/signing` (it is ignored by git) and run `unset APPLE_TEAM_ID NOTARY_PROFILE APP`.

---

### Task 6: Docs, the checklist, the full check and the pull request

**Files:**
- Modify: `docs/superpowers/specs/2026-11-01-signing-notarization-design.md`
- Modify: `README.md` (the built list, `## Planned`, `## Releases`)
- Modify: `docs/product/mvp-implementation-checklist.md` (Progress and Prioritized Backlog)
- Modify: `docs/decisions/0005-developer-id-without-app-sandbox.md` (`## Not Yet Verified`)
- Modify: `docs/architecture/gap-analysis.md` (Release row, Not present line, the signed-build gap)

Write what Task 5 showed, with its date. If a Task 5 step did not pass or was not done, leave it out of the verified text and name it in the "missing" column instead.

- [ ] **Step 1: Fold the deviations into the spec**

In the spec:
- Under `## Scripts`, before `### scripts/sign-app.sh APP`, add:

```markdown
`scripts/signing-identity.sh` prints the identity's SHA-1 by the rule below, and `scripts/check-signature.sh CODE...` checks each signature's team, hardened runtime and timestamp; `sign-app.sh` and `sign-binary.sh` both use them.
```

- In `### scripts/sign-app.sh APP`, change the start of the third paragraph to `The identity (signing-identity.sh) is`.
- In `## The release workflow`, step 2, after `added to the search list.`, add: `Apple's Developer ID G2 intermediate (from apple.com) is imported into it too, so the chain does not depend on the runner image, and the step checks that exactly one identity of the team is there.` Before the numbered list, change `After picking the build (B47):` to `It picks the build (B47) first, so a bad tag fails before any work, then:`.
- In `## The release workflow`, last paragraph: `` `app-build.yml` does not change: pull requests build unsigned, and pull requests from forks never see the secrets. `ci.yml` runs `scripts/test-signing.sh`. ``
- In `## Tests`, replace the second bullet with: ``- `scripts/test-signing.sh`, in CI's build job, runs the scripts against a stand-in for `security`: `signing-identity.sh`, `sign-app.sh` and `sign-binary.sh` refuse without `APPLE_TEAM_ID`, without an identity of that team, and with several identities and no `SIGNING_IDENTITY`; `check-signature.sh` refuses unsigned and ad hoc code; `notarize.sh` refuses without credentials, naming the missing ones.``

- [ ] **Step 2: README**

In the built list (above `## Planned`), after the bullet that starts `- Swift 6 with strict concurrency`, add:

```markdown
- Tagged builds signed with Developer ID and notarized by the release workflow: Runnir.app with its helpers, and the macOS Core binaries (B48). Checked on a Mac with a beta build on <date>; not yet run from a tag.
```

In `## Planned`, replace `- Distribution work: Developer ID signing, notarization, packaging and secure automatic updates; completion is not claimed.` with:

```markdown
- Distribution work: the first signed build from a tag, packaging beyond a zip and secure automatic updates; completion is not claimed.
```

In `## Releases`, replace the paragraph that starts `The release workflow builds an unsigned draft app` with:

````markdown
The release workflow runs in the GitHub environment `release`, which only `v*` tags reach. It builds the app and the Core binaries, signs Runnir.app (with `runnir-core` and `act` inside) and the macOS Core binaries with Developer ID, the hardened runtime and a secure timestamp, has Apple notarize them, staples the app and attaches `Runnir-<tag>.zip` and the binaries to a draft release; after it uploads them it downloads them back and checks their SHA-256 against the built files. A tag fails, naming what is missing, when one of the secrets `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` or the variable `APPLE_TEAM_ID` is not set. The Linux and Windows binaries are not signed. Release assets are the only build output CI keeps: pull request and `main` runs build and check the app and Core but upload no Actions artifacts, and no workflow saves Actions caches. Release notes, packaging beyond a zip and automatic updates remain planned.

The same scripts sign and notarize a local archive, with the Developer ID certificate in the login keychain and a `notarytool` keychain profile (`xcrun notarytool store-credentials`). The team ID comes from the environment and is never written into the repository:

```bash
export APPLE_TEAM_ID=<team ID> NOTARY_PROFILE=<profile> APP=build/Runnir.xcarchive/Products/Applications/Runnir.app
scripts/sign-app.sh "$APP"
ditto -c -k --keepParent "$APP" build/Runnir-notarize.zip
scripts/notarize.sh build/Runnir-notarize.zip
scripts/staple-app.sh "$APP"
```

With several valid Developer ID identities of the team, set `SIGNING_IDENTITY` to the SHA-1 of the one to use. `scripts/test-signing.sh` checks the scripts' refusals.
````

- [ ] **Step 3: The checklist**

In `## Progress`, after the `| B47 |` row, add (adjust the checked part to Task 5):

```markdown
| B48 | Tagged builds are signed and notarized ([spec](../superpowers/specs/2026-11-01-signing-notarization-design.md)): the release workflow runs in the `release` environment (tags `v*` only), signs Runnir.app inside out (Frameworks, `runnir-core`, `act`, the app) and the darwin Core binaries with Developer ID, the hardened runtime and a secure timestamp from a temporary keychain, notarizes them with an App Store Connect API key, staples the app and publishes `Runnir-<tag>.zip`; a missing secret or `APPLE_TEAM_ID` fails the tag; the scripts also run on a Mac, and `scripts/test-signing.sh` checks their refusals in CI; on <date> a beta signed, notarized and stapled on a Mac passed `spctl` as Notarized Developer ID, opened from quarantine, kept its sign-in, read a folder and started its Core | A run of the release workflow from a tag |
```

In `## Prioritized Backlog`, after the `| B47 |` row, add:

```markdown
| B48 | P1 / v0.1 | Tagged builds (release, alpha, beta) are signed with Developer ID and notarized: the app with its helpers and the macOS Core binaries ([spec](../superpowers/specs/2026-11-01-signing-notarization-design.md)) | B47, ADR 0005 | Signing and notarization scripts that run on a Mac and in CI; the release workflow in the `release` environment with a temporary keychain; a missing credential fails the tag; `spctl` reports Notarized Developer ID; refusal tests in CI; a signed beta checked on a Mac; the first tag checks the CI path |
```

- [ ] **Step 4: ADR 0005 and the gap analysis**

Replace the body of `## Not Yet Verified` in ADR 0005 with:

```markdown
A build signed by the release workflow from a tag. On <date> a beta build signed with Developer ID by the same scripts on a Mac, notarized and stapled (B48), passed `spctl` as Notarized Developer ID, opened from quarantine, kept its GitHub sign-in in Keychain across a relaunch, read a chosen folder and started its Core under the hardened runtime. The data-protection keychain is not adopted.
```

In `docs/architecture/gap-analysis.md`:
- Replace the `| Release (B17) |` row with:

```markdown
| Release (B17) | Partly implemented | `Release Build` workflow signs the app and the macOS Core binaries with Developer ID, notarizes them and creates draft release assets on version tags (B48); a signed beta checked on a Mac | A run of the signing path from a tag, an updater, the license decision and the end-to-end acceptance checklist; no distribution claim until then |
```

- In the `- **Not present:**` line, replace `a signed build.` with `a signed build from the release workflow.`
- Replace the `| No Developer ID signed, notarized build |` row with:

```markdown
| No signed build from a tag yet | FR-01, FR-05, FR-06, B17 | Push the first tag and check the release workflow's signed, notarized app; repeat the folder-grant, process and container checks on it (a beta signed on a Mac passed the Keychain, folder and Core checks, B48). No updater claim before |
```

- [ ] **Step 5: The full check**

Run, from the repository root:

```bash
scripts/test-signing.sh
```

```bash
shellcheck scripts/signing-identity.sh scripts/check-signature.sh scripts/sign-binary.sh scripts/sign-app.sh scripts/notarize.sh scripts/staple-app.sh scripts/test-signing.sh
```

```bash
cd core && go run github.com/rhysd/actionlint/cmd/actionlint ../.github/workflows/release.yml ../.github/workflows/ci.yml ../.github/workflows/app-build.yml
```

```bash
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build
```

```bash
grep -rn -e "$(gh variable get APPLE_TEAM_ID --env release --repo dil-eight/runnir)" --exclude-dir=.git --exclude-dir=build . || echo "team ID not in the repository"
```

Expected: `All signing script checks passed`; no shellcheck or actionlint output; `** BUILD SUCCEEDED **`; `team ID not in the repository`. No Swift or Go code changed, so the unit tests and `go test` are not needed; run them anyway if anything outside `scripts/`, `.github/` and `docs/` changed.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-11-01-signing-notarization-design.md README.md docs/product/mvp-implementation-checklist.md docs/decisions/0005-developer-id-without-app-sandbox.md docs/architecture/gap-analysis.md
git commit -m "Docs: B48 built, signing on a Mac and in the release workflow"
```

- [ ] **Step 7: The pull request, once #56 is merged**

Only after the user merges #56:

```bash
git fetch origin && git rebase --onto origin/main dilbarov/build-marks dilbarov/signing
```

Resolve conflicts if #56 changed after `dilbarov/signing` was cut, rerun Step 5, then push and open the PR with the user's go-ahead:

```bash
git push -u origin dilbarov/signing
```

PR title `B48: sign and notarize tagged builds`; the description says what was checked on a Mac (Task 5, with the date) and that the release workflow's path is verified only by the first tag. No AI attribution in the title, description or commits.
