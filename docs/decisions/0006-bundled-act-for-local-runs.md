# 0006 Bundled act for Local Runs

Status: accepted, 2026-10-20.

## Context

Local runs (FR-06) execute workflows with [act](https://github.com/nektos/act) on the user's Docker-compatible engine. Runnir drives act through its command line and its JSON log format (`--json`). Neither is a stable API: act is still 0.x, flags get deprecated, and log fields can change. Supporting every act a user may have installed would mean testing a version matrix. The engine is different: Runnir only uses long-stable Docker CLI commands, and act negotiates the Engine API version itself.

## Decision

- Runnir bundles one act version, the one local runs were verified with, and uses it by default. It is built from source during the app build from the module pinned in `third_party/act` (currently v0.2.89). `go.sum` checks every module it is built from, so nothing is downloaded as a prebuilt binary. Like the Core, it is a universal helper in `Contents/Helpers/act`, signed with the hardened runtime and no entitlements. act's MIT license ships in `Contents/Resources/Licenses`.
- Settings has an experimental switch, **Use installed act**, which is off by default. When it is on and an installed act is usable (0.2.60 or newer, found in the shell `PATH` or the usual install locations), runs use that act instead. Versions newer than the bundled one are labelled as not verified. Without a usable installed act, runs use the bundled act, and the review says so.
- The container engine stays the user's own (OrbStack, Docker Desktop, Colima or another Docker-compatible engine), reached through the current Docker context. The engine needs Engine API 1.41 (Docker 20.10) or newer. An engine whose context points at another computer is refused. Runnir never installs a tool, starts an engine or switches the context.
- Every run uses a fixed act command line. Nothing from the repository adds flags. The command line enforces the following:
  - the run's workflow, job and event come from the reviewed plan;
  - `--json` and `--rm`;
  - `--pull=false`, so an image is downloaded only when it is missing;
  - `--network bridge`, not the engine's host network, which on some engines reaches the Mac's own services;
  - `--no-cache-server`, because the cache server listens on a network address of the Mac;
  - `--container-daemon-socket -`, so the engine's socket is never mounted;
  - empty `--env-file`, `--secret-file`, `--var-file` and `--input-file`, so a repository's `.env`, `.secrets`, `.vars` or `.input` is never read;
  - job containers get a label with the run's id and CPU and memory limits;
  - every runner label act can stand in for is mapped to act's medium images.
- act runs in a private scratch directory, with its own home and configuration directories. This keeps the user's and the repository's `.actrc` from applying. act gets no Docker credentials and no environment from the Core. `ACT_DISABLE_VERSION_CHECK=1` stops act's request to its notice service, which would otherwise send act's version, OS and architecture on every start.
- Local runs go one at a time. act names containers after the workflow and job, so two runs at once could replace each other's containers.

## Consequences

- The app grows by about 20 MB per architecture, and the app build compiles act (cached after the first build).
- Updating act is a deliberate change: bump `third_party/act`, run the local-run tests, including `go test -tags e2e ./internal/localrun/` against a real engine, and update `TestedActVersion` in the Core.
- act's dependencies (including Docker and go-git libraries) are redistributed in the bundled binary. Their license notices still have to be collected for a release. Only act's own license ships today.
- Known vulnerabilities in the bundled act are Runnir's to handle. `third_party/act` raises act's dependencies where a fixed version is compatible: go-git 5.19.3, golang.org/x/crypto 0.58.0 and the x/net, x/sys and related modules they need, which fixes 18 findings that govulncheck reports for act 0.2.89 as released. CI scans the bundled act every week and on changes. GO-2026-6253 in moby/go-archive (a crafted tar archive can be written outside its extraction directory) stays open: the fixed versions remove an API act 0.2.89 uses. act reaches that package when it builds the image of a local Docker action (`uses: ./path` with a Dockerfile). It stays listed as a known finding until an act release supports the fixed version.
- Containers act creates for services, or for jobs that set their own `container:` image, do not get Runnir's label or limits, because act passes container options only to job containers without a `container:` section. act removes those containers itself when it ends or is interrupted. If act has to be killed after the grace period, Runnir says that containers may remain.

## Verified

- On OrbStack with the bundled act v0.2.89 and the raised dependencies (end-to-end tests under the `e2e` build tag):
  - a job ran and its output and state came through;
  - the engine's socket was absent in the job;
  - secrets and `GITHUB_TOKEN` were empty;
  - a repository `.env`, `.secrets` and `.actrc` did not apply;
  - uncommitted files were copied and `.gitignore`d files were not;
  - a job container carried the run's label, 2 CPUs, 512 MB and the bridge network;
  - cancelling stopped the run in under a second and left no containers.
- Not tested yet:
  - a run with the default runner images (`catthehacker/ubuntu:act-*`, over 1 GB);
  - remote actions fetched with the raised go-git version.
