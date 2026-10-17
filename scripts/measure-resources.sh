#!/bin/sh
# Measures idle memory and CPU of Runnir (app + Core) with N open repositories.
#
#   scripts/measure-resources.sh [-a path/to/Runnir.app] [-c "1 3 10"] [-s settle_seconds] [-i cpu_interval_seconds]
#
# For each count it builds that many fixture repositories (six workflow files each),
# launches the app on an empty isolated session and has it open one window per
# repository (a Debug-only hook, so the bookmarks belong to the app), waits until the Core reports all repositories open, lets the app settle, then
# reports the physical footprint (what Activity Monitor calls Memory) of the app and
# of its Core child, and their average CPU use over the sampling interval.
#
# Needs a Debug build of the app (the isolated session and import hooks exist only
# there), `footprint` and `grpcurl`. It touches nothing outside a temporary
# directory and quits the app it launched. Results are for the machine they ran on.
set -eu

app=""
counts="1 3 10"
settle=30
interval=30
while getopts "a:c:s:i:" option; do
    case "$option" in
        a) app="$OPTARG" ;;
        c) counts="$OPTARG" ;;
        s) settle="$OPTARG" ;;
        i) interval="$OPTARG" ;;
        *) echo "usage: $0 [-a Runnir.app] [-c \"1 3 10\"] [-s settle] [-i interval]" >&2; exit 2 ;;
    esac
done

root=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "$app" ]; then
    app=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Runnir-*/Build/Products/Debug/Runnir.app 2>/dev/null | head -1 || true)
fi
[ -d "$app" ] || { echo "No Debug Runnir.app found; build it or pass -a." >&2; exit 1; }
for tool in footprint grpcurl; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done

if pgrep -f "runnir-core serve" >/dev/null; then
    echo "A Runnir Core is already running; quit Runnir first so the measurement owns the only Core." >&2
    exit 1
fi

work=$(mktemp -d /tmp/rnmeasureXXXXXX)
app_pid=""
cleanup() {
    [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

# Footprint in MB for a pid ("Footprint: 123 MB" or KB/GB).
footprint_mb() {
    footprint -p "$1" 2>/dev/null | awk '{
        for (i = 1; i < NF; i++) if ($i == "Footprint:") {
            value = $(i + 1) + 0; unit = $(i + 2)
            if (unit == "KB") value /= 1024; else if (unit == "GB") value *= 1024
            printf "%.1f", value; exit
        } }'
}

# CPU seconds used so far, from ps "[[dd-]hh:]mm:ss.cc".
cpu_seconds() {
    ps -o time= -p "$1" | awk '{
        n = split($1, part, /[-:]/); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + part[i]
        printf "%.2f", s }'
}

make_fixture() {
    repo="$1"
    mkdir -p "$repo/.git" "$repo/.github/workflows"
    echo "ref: refs/heads/main" > "$repo/.git/HEAD"
    for n in 1 2 3 4 5 6; do
        cat > "$repo/.github/workflows/workflow$n.yml" <<YAML
name: Workflow $n
on:
  push:
    branches: [main]
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - run: echo build $n
  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - run: echo test $n
YAML
    done
}

core_socket="$(getconf DARWIN_USER_TEMP_DIR)runnir-core.sock"
call() { grpcurl -plaintext -import-path "$root/contracts/grpc" -proto runnir/core/v1/runnir_core.proto "$@"; }

printf '| Repos | App MB | Core MB | Total MB | App CPU %% | Core CPU %% | Core processes |\n'
printf '| ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n'

for count in $counts; do
    state="$work/state-$count"
    repos=""
    i=1
    while [ "$i" -le "$count" ]; do
        make_fixture "$work/repo-$count-$i"
        repos="$repos $work/repo-$count-$i"
        i=$((i + 1))
    done
    mkdir -p "$state"
    import_paths=$(echo "$repos" | tr ' ' ':' | sed 's/^://')

    rm -f "$core_socket"
    RUNNIR_UI_TEST_STATE_DIRECTORY="$state" RUNNIR_UI_TEST_IMPORT_PATHS="$import_paths" \
        "$app/Contents/MacOS/Runnir" --ui-testing >/dev/null 2>&1 &
    app_pid=$!

    # Wait for the Core to report every repository open.
    waited=0
    opened=0
    while [ "$waited" -lt 60 ]; do
        sleep 1
        waited=$((waited + 1))
        opened=$(call "unix://$core_socket" runnir.core.v1.RunnirCore/HealthCheck 2>/dev/null \
            | awk -F'[:,]' '/openRepositoryCount/ {gsub(/ /, "", $2); print $2}' || true)
        [ "${opened:-0}" = "$count" ] && break
    done
    if [ "${opened:-0}" != "$count" ]; then
        echo "Core reported ${opened:-0} of $count repositories after 60 s." >&2
        exit 1
    fi

    sleep "$settle"
    core_pid=$(pgrep -P "$app_pid" -f "runnir-core serve" | head -1)
    processes=$(pgrep -f "runnir-core serve" | wc -l | tr -d ' ')
    app_mb=$(footprint_mb "$app_pid")
    core_mb=$(footprint_mb "$core_pid")

    app_cpu_before=$(cpu_seconds "$app_pid")
    core_cpu_before=$(cpu_seconds "$core_pid")
    sleep "$interval"
    app_cpu_after=$(cpu_seconds "$app_pid")
    core_cpu_after=$(cpu_seconds "$core_pid")

    app_cpu=$(awk -v a="$app_cpu_before" -v b="$app_cpu_after" -v t="$interval" 'BEGIN {printf "%.1f", (b - a) / t * 100}')
    core_cpu=$(awk -v a="$core_cpu_before" -v b="$core_cpu_after" -v t="$interval" 'BEGIN {printf "%.1f", (b - a) / t * 100}')
    total=$(awk -v a="$app_mb" -v b="$core_mb" 'BEGIN {printf "%.1f", a + b}')
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$count" "$app_mb" "$core_mb" "$total" "$app_cpu" "$core_cpu" "$processes"

    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""
    sleep 2
done

echo
echo "Internal target: at most 300 MB combined with 10 repositories and no executions (not a guarantee)."
echo "App: $app"
