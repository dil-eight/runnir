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
mkdir -p "$destination" "${DERIVED_FILE_DIR}/core"
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

# Xcode's ARCHS is a trusted, whitespace-separated build setting.
set --
for arch in $ARCHS; do
    set -- "$@" "${DERIVED_FILE_DIR}/core/runnir-${arch}"
done
/usr/bin/lipo -create "$@" -output "${destination}/runnir-core"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    /usr/bin/codesign --force --options runtime \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
        --entitlements "${SRCROOT}/../../core/macos-helper.entitlements" \
        "${destination}/runnir-core"
fi
