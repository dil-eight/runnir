# Repository Presets From .runnir/launches (B25)

Status: design approved and implemented on 2026-10-23 ([plan](../plans/2026-10-23-repository-presets.md)). Change made while planning: instead of a `PresetChoice` enum, a repository preset gets a name-based id from the workspace and its file (`CoreLaunchPreset.presetID`), so the Overview's `(workflowID, presetID)` callback and the form's apply logic stay as they were; `CoreLaunchPreset` lives in `CoreService.swift` next to `CoreWorkflow`. Changes after review: the app lists usable presets as Finder sorts names (`localizedStandardCompare`, then path), the Core's order only keeps the list deterministic; `ListWorkflows` returns each local workflow's `workflow_dispatch` inputs so the Overview judges secret-looking values with the input's description, as Run Workflow does; the preset menu stays usable for repository presets when the presets file on this Mac cannot be read; only the latest started read of the presets lands, and a cancelled read is not shown as a failure; a file name that is not valid UTF-8 is shown with replacement characters instead of failing the list. Backlog: B25 / F2 in the [MVP checklist](../../product/mvp-implementation-checklist.md); it completes B09's "portable presets". Context: [ADR 0003](../../decisions/0003-workspaces-sessions-offline-storage.md), [workspace persistence](../../architecture/workspace-persistence.md), [gRPC API](../../architecture/grpc-api.md). Designs: `docs/design/runnir.pen`, frames "S03 / Repository overview / Run manually: repository and Mac presets, one unusable file" (row B) and "S06 / Manual run sheet / Preset menu: repository and Mac presets" (row C).

## Goal

A team keeps Run Workflow presets in the repository, in `.runnir/launches/*.yaml`, and everyone who opens the working tree in Runnir sees them next to the presets kept on their own Mac. Runnir only reads these files: it checks them, lists them in Overview › Run manually and in the Run Workflow preset menu, and applies them to the form. It never creates, changes or deletes them.

## Decisions Made

| Question | Decision |
| --- | --- |
| What `.runnir` holds in B25 | Only `launches/*.yaml`. `config.yaml` and `environments.yaml` from the earlier plan are not introduced: nothing would use them yet |
| Secrets | Never in `.runnir`. Secrets for local runs are B28's: the names come from `secrets.X` in the workflow itself, the user enters a value or keeps it in Keychain, a stored value is shown only after Touch ID or the password. No Runnir file format for secrets or environments |
| Targets | A preset runs a workflow on GitHub through Run Workflow. Local runs from a preset come later with a schema change |
| Where presets show | Overview › Run manually (right column), group "IN THIS REPOSITORY · .runnir/launches" above "ON THIS MAC"; the Run Workflow preset menu, sections "In This Repository" and "On This Mac" |
| Who reads and checks the files | The Go Core, in the same scan as `.github/workflows` (ADR 0003: repository config interpretation is Core-owned). The app only shows and applies |
| Storage | None. The result lives in the repository snapshot next to the workflows; the files are the source |
| When files are read | Opening a repository, Refresh, and any rescan that announces `REPOSITORY_REFRESHED`. No file watching yet, as for workflows |
| File format versioning | None before the first release tag (AGENTS.md: no backward compatibility until then). No `version` field |
| Unknown keys | An error: the file is not used. Silently ignoring something the author wrote (for example a future `target: local`) would run the wrong thing |
| Inputs that look secret | Their values are not applied: GitHub logs dispatch inputs in plain text. A note under the menu names them. Same heuristic as presets on this Mac (`DispatchPreset.looksSecret`) |

## File Format

```yaml
# .runnir/launches/deploy-staging.yaml
name: Deploy to staging
workflow: deploy.yml
ref: main
inputs:
  environment: staging
  dry_run: false
```

| Key | Required | Rule |
| --- | --- | --- |
| `name` | yes | A string of 1–80 characters after trimming, one line |
| `workflow` | yes | A file name directly in `.github/workflows`, ending in `.yml` or `.yaml`: no `/`, `\`, `.` or `..`. It must name a workflow file the same scan found, compared exactly (GitHub paths are case-sensitive) |
| `ref` | no | A branch or tag name: 1–255 characters, no whitespace or control characters. Absent: the form keeps its branch |
| `inputs` | no | A mapping of at most 25 entries. Keys: 1–100 characters. Values: a string, number or boolean scalar of at most 4096 characters, sent as written (`false` stays `false`). A null, sequence or mapping value is an error |

The document must be a single YAML mapping. Duplicate keys, an empty file, more than one document, and invalid YAML are errors; a YAML error carries its line number. Aliases are followed a bounded number of steps and never expanded wholesale, as in workflow parsing. Nothing is evaluated: `${{ }}` stays text.

## Reading Rules (Core)

- `.runnir` and `.runnir/launches` must be directories, checked with `lstat`. A missing one means no presets and no message: having no `.runnir` is normal.
- A symlinked or non-directory `.runnir` or `launches` is not followed and gives one entry for that folder, for example ".runnir/launches is a symbolic link; Runnir does not follow links" (or "is not a folder").
- A folder the Core may not read gives one entry: "Can't read .runnir/launches". It never looks like an empty folder, and it never fails the repository scan: workflows still open.
- Only regular files directly in `launches` whose extension is `.yml` or `.yaml` (any case) are read, in name order; subfolders and other files are ignored. A symlinked file is not followed and gets an entry saying so.
- At most 100 files of at most 64 KiB each. A larger file gets "file is larger than 64 KiB"; after 100 files the rest are skipped with one entry for the folder: "Only the first 100 files are read".
- Messages are bounded to 200 characters of valid UTF-8 (the scanner's `truncate`).
- Two presets may share a name. Usable presets sort by name, then by file; entries with a problem follow, by path.

## Core Changes

- `internal/repository`: `Snapshot` gains `LaunchPresets []LaunchPreset`; `LaunchPreset{Path, Name, WorkflowPath, Ref, Inputs map[string]string, Problem}`, where `Path` is `.runnir/launches/<file>`, or `.runnir` or `.runnir/launches` for an entry about that folder, and `Problem` is empty for a usable preset. `Manager.LaunchPresets(id)` returns the current snapshot's list, like `Workflows(id)`.
- `internal/scanner`: a `launches.go` reads the folder with the rules above and parses each file with `go.yaml.in/yaml/v3` nodes, reusing `readBounded`, `resolve` and `truncate`. `Scan` reads presets after workflows and checks `workflow` against the workflow ids of the same scan. A presets problem never fails `Scan`.
- `internal/server`: `ListLaunchPresets` maps the list; an unknown repository is `NOT_FOUND`, as for `ListWorkflows`.

## gRPC Contract (`runnir.core.v1`)

```proto
// Portable Run Workflow presets in .runnir/launches of an open repository,
// read in the same scan as its workflows. Runnir never writes these files.
rpc ListLaunchPresets(ListLaunchPresetsRequest) returns (ListLaunchPresetsResponse);

message ListLaunchPresetsRequest {
  string repository_id = 1;
}

message ListLaunchPresetsResponse {
  // Usable presets by name, then path; entries with a problem after them, by path.
  repeated LaunchPreset presets = 1;
}

message LaunchPreset {
  // ".runnir/launches/<file>", or ".runnir" / ".runnir/launches" for a problem with that folder.
  string path = 1;
  string name = 2;
  // ".github/workflows/<file>"
  string workflow_path = 3;
  // Empty: keep the branch the form has.
  string ref = 4;
  map<string, string> inputs = 5;
  // Why the entry cannot be used; empty when it can. Other fields may be empty then.
  string problem = 6;
}
```

## App (Swift)

- `CoreService.listLaunchPresets(repositoryID:)` and a `CoreLaunchPreset` model in `CoreWorkspaceModels.swift`.
- `RepositorySession` gains `launchPresets: [CoreLaunchPreset]` and `launchPresetsError: String?`. `CoreHub` reads them wherever it reads workflows: `open`, `refresh` and `reloadWorkflows` (the `REPOSITORY_REFRESHED` path). A failed read keeps the previous list and sets the error; it never fails opening the repository.
- A preset choice names its source: `enum PresetChoice: Hashable { case thisMac(UUID); case repository(path: String) }`. Overview's `runWorkflow` and the Run Workflow model take a `PresetChoice?` instead of a preset UUID.
- Run Workflow (`RunWorkflowModel`): the menu lists the selected workflow's repository presets, then its presets on this Mac. Applying a repository preset uses the existing path (branch first, then the workflow's defaults with the preset's values on top, notes for what no longer fits) and also leaves out values of inputs that look secret, with the note "Not applied because it looks secret: token". While a repository preset is applied the menu offers "Save as New Preset…" (saves a copy on this Mac) and the disabled hint "Edit .runnir/launches/<file> to change this preset" instead of Update, Rename and Delete. `presetIsModified` works for both sources.
- Overview › Run manually: "IN THIS REPOSITORY" with the source path on the right, then "ON THIS MAC", then the footnote "Repository presets are shared through Git. Runnir reads them and never changes them." The repository group is shown only when there are entries (an empty `launches` folder shows nothing). Rows:
  - usable, workflow on GitHub and active: name, detail "workflow · ref · key=value", Run (enabled as for Mac presets);
  - usable, workflow not among GitHub's workflows while that list is known: Run disabled, detail ends "not on GitHub yet"; while it is not known (no remote, no access), Run is disabled as for presets on this Mac;
  - problem: warning symbol, the file name in monospace, the problem text, no Run;
  - `launchPresetsError`: one warning row with it.
  Values of inputs that look secret show as `•••` in the detail line.
- Device presets (`dispatch-presets.json`) do not change.

## Error Handling Summary

| Case | Result |
| --- | --- |
| No `.runnir`, no `launches`, or an empty `launches` | No repository group, nothing logged |
| Folder is a symlink, a file or unreadable | One warning row for the folder; workflows unaffected |
| File too large, symlinked, unreadable, invalid or unusable | One warning row for the file; never in the Run Workflow menu |
| More than 100 files | First 100 by name plus one folder row |
| `ListLaunchPresets` fails | Previous list stays; one warning row with the reason |
| Preset's branch gone, input removed or choice no longer offered | Existing preset notes under the menu |
| Input looks secret | Value not applied; note names it |

## Tests

- Go, parsing (table-driven): every rule in File Format, including duplicate keys, multiple documents, null and nested input values, 26 inputs, a 4097-character value, a 256-character ref, whitespace in a ref, `workflow` with a path or `..`, a missing workflow, case mismatch, an alias chain, invalid YAML with its line.
- Go, scanner (temporary folders): no `.runnir`, symlinked `.runnir` and `launches`, `launches` as a file, unreadable folder (skipped when running as root), a symlinked file, a 64 KiB + 1 file, 101 files, subfolders and other extensions ignored, name order, presets problems never failing `Scan`.
- Go, server: `ListLaunchPresets` for an open repository, `NOT_FOUND` for an unknown one, a file added on disk appears after `RefreshRepository`.
- Swift unit tests: `CoreHub` loads presets on open, refresh and `REPOSITORY_REFRESHED` and keeps them on a failed read; Overview row building for each row kind; Run Workflow applies a repository preset's branch and inputs, leaves out secret-looking values with a note, offers no Update, Rename or Delete for it, and "Save as New Preset…" stores a copy on this Mac.
- Commands: the build and RunnirTests commands in AGENTS.md; `go test ./...`, `go vet ./...`, `go build ./...` in `core/`; contracts regenerated with `scripts/generate-contracts.sh`.
- Live check in the Debug test copy (`--ui-testing`, its own state folder) on a repository with valid, invalid and missing-workflow presets: Overview groups and rows, the Run Workflow menu, applying a preset, a file added on disk showing after Refresh.

## Documentation

- `workspace-persistence.md`: the `.runnir` section describes only `launches/*.yaml` as implemented, removes the `config.yaml`/`environments.yaml`/`keychain://` examples, and records the B28 direction for local-run secrets as a plan.
- ADR 0003: `.runnir` holds portable launch presets (implemented); config and environment files are not introduced.
- `specification.md` (FR-03, FR-09) and the MVP checklist: B25 progress row; B09 no longer missing B25; B25 and B28 backlog lines reworded (B28: local-run secrets from the workflow's references, entered or kept in Keychain, shown after Touch ID; environments built on the user's own tools, no Runnir format).
- `grpc-api.md`: `ListLaunchPresets`. `screens-and-states.md`: the new S03 and S06 states; S16 and S17 were drawn for the earlier plan and are revisited in B28.

Also in this change: AGENTS.md states that backward compatibility starts with the first release tag; `grpc-api.md` and ADR 0004 say the contract changes in place until then, and CI runs `buf breaking` only once a `v*` tag exists.

## Not Verified By This Work

A Developer ID signed build reading `.runnir` (as for the other repository reads); dispatching a repository preset against github.com itself beyond the controlled checks already listed for B10.
