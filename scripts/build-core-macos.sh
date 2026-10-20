#!/bin/sh
set -eu

# The Go on PATH (for example from setup-go or the developer's shell) wins;
# the usual install locations are only fallbacks for Xcode's minimal PATH.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin"
export CGO_ENABLED=0
export GOOS=darwin
export GOTOOLCHAIN=local
export GOCACHE="${DERIVED_FILE_DIR}/go-cache"
export GOPATH="${DERIVED_FILE_DIR}/go-path"
export GOTELEMETRY=off

destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
licenses="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Licenses"
mkdir -p "$destination" "$licenses" "${DERIVED_FILE_DIR}/core"
cd "${SRCROOT}/../../core"

for arch in $ARCHS; do
    case "$arch" in
        arm64) export GOARCH=arm64 ;;
        x86_64) export GOARCH=amd64 ;;
        *) echo "Unsupported macOS architecture" >&2; exit 1 ;;
    esac
    go build -trimpath -ldflags "-X runnir/core/internal/buildinfo.Version=${MARKETING_VERSION}" \
        -o "${DERIVED_FILE_DIR}/core/runnir-${arch}" ./cmd/runnir
done

# act for local runs, built from the version pinned in third_party/act
# (ADR 0006); go.sum checks every module it is built from.
cd "${SRCROOT}/../../third_party/act"
for arch in $ARCHS; do
    case "$arch" in
        arm64) export GOARCH=arm64 ;;
        x86_64) export GOARCH=amd64 ;;
    esac
    go build -trimpath -ldflags "-s -w" -o "${DERIVED_FILE_DIR}/core/act-${arch}" github.com/nektos/act
done
cp "$(go list -m -f '{{.Dir}}' github.com/nektos/act)/LICENSE" "${licenses}/act-LICENSE.txt"
chmod 0644 "${licenses}/act-LICENSE.txt"

# Xcode's ARCHS is a trusted, whitespace-separated build setting.
for helper in runnir act; do
    set --
    for arch in $ARCHS; do
        set -- "$@" "${DERIVED_FILE_DIR}/core/${helper}-${arch}"
    done
    name="$helper"
    [ "$helper" = runnir ] && name=runnir-core
    /usr/bin/lipo -create "$@" -output "${destination}/${name}"
done

# The helpers run with the hardened runtime and no entitlements: no App
# Sandbox to inherit (ADR 0005).
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    for name in runnir-core act; do
        /usr/bin/codesign --force --options runtime \
            --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
            "${destination}/${name}"
    done
fi
