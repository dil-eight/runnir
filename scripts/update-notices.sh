#!/bin/sh
# Regenerate the third-party license notices (B49): licenses/notices.json and
# licenses/Runnir-LICENSE.txt for the app, core/internal/licenses for
# `runnir licenses`. The files are committed; CI (app-build.yml) runs the same
# generator with -check and fails when they differ. Needs Go and Xcode: the
# app's Swift packages are checked out into build/notices/SourcePackages.
set -eu
cd "$(dirname "$0")/.."
exec go -C tools/notices run . -root "$PWD" "$@"
