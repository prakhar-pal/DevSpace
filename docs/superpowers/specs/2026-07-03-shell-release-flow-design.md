# Shell-based, git-native release flow (replacing changesets/Node)

Date: 2026-07-03
Status: Proposed

## Context

The version pipeline still assumes the old Tauri app: changesets (`.changeset/`)
at the repo root, an npm `package.json`, and a Node `sync-version.js`. The native
Swift app builds via SwiftPM with no Node toolchain, and its version lives in
`Info.plist` (`CFBundleShortVersionString`, read at runtime by
`DevSpaceCore.version` and stamped into the bundle by `scripts/assemble-app.sh`).

We want to drop the Node dependency and manage the version with plain shell +
git, driven by conventional-commit titles.

## Goals

- No Node/npm dependency; pure `bash` + `git`.
- On every merge to `main`, maintain a single "release" PR that accumulates the
  changelog and the pending version bump.
- Merging that release PR bumps the app version on `main` and creates a git tag.
- Version bump level derived from conventional-commit titles.

## Non-goals

- Building / signing / notarizing / distributing the `.app`. A Developer ID +
  notarization release pipeline is separate future work.
- Publishing to any package registry.

## Version model

- Source of truth: `Info.plist` `CFBundleShortVersionString` (e.g. `0.3.4`).
- Releases are marked by annotated git tags `vX.Y.Z`.
- "Last released version" = the most recent `v*` tag (via
  `git describe --tags --match 'v*' --abbrev=0`). If no tag exists, the current
  `Info.plist` version is the baseline.

## Bump rule (conventional commits)

Scan `git log <lastTag>..HEAD` first-line subjects (merge commits and
`chore: release` commits excluded):

- `feat` / `feat(scope)` → **minor**
- `fix` / `perf` / `refactor` (± scope) → **patch**
- any type with `!` (e.g. `feat!:`) or a body containing `BREAKING CHANGE` → **major**
- `chore` / `docs` / `style` / `test` / `ci` / `build` → not releasable on their
  own (recorded under "Other" only if a release is otherwise triggered)

Highest level wins. If no releasable commits since the last tag → no release PR.
While `0.y.z` (pre-1.0), a "major" bump is applied as a minor bump (documented in
the script), matching common pre-1.0 practice; this can be revisited at 1.0.

## Components

### `scripts/next-version.sh` (pure computation, no side effects)
Inputs: the repo (git) + `Info.plist`. Prints two lines to stdout:
```
bump=<major|minor|patch|none>
version=<X.Y.Z>          # the computed next version (current version if none)
```
Locally runnable for testing. Contains the semver parse/bump helpers.

### `scripts/prepare-release.sh` (applies the release to the working tree)
1. Runs `next-version.sh`; exits non-zero/`none` if nothing to release.
2. Rewrites `Info.plist` `CFBundleShortVersionString` to the new version
   (same targeted `sed`/regex approach as the retired `sync-version.js`).
3. Prepends a dated section to `CHANGELOG.md`:
   ```
   ## vX.Y.Z - YYYY-MM-DD

   ### Features
   - <subject> (<shortsha>)
   ### Fixes
   - <subject> (<shortsha>)
   ### Other
   - <subject> (<shortsha>)
   ```
   (Empty groups omitted.) Date from `date -u +%Y-%m-%d` (CI runtime; not a
   resumable-workflow script, so wall-clock is fine.)
Leaves changes in the working tree for the workflow to commit to `release/main`.

### `.github/workflows/release.yml` (single job, `on: push: [main]`)
Uses the default `GITHUB_TOKEN`. Sequential, message-independent steps:

1. **Tag-if-untagged:** read `Info.plist` version `X.Y.Z`; if tag `vX.Y.Z` is
   absent, create an annotated tag on the current commit and push it. This is
   what fires when a release PR merges (the bump already landed on `main`).
2. **Refresh release PR:** run `prepare-release.sh`. If it reports `none`, exit.
   Otherwise force-update branch `release/main` with the bump + changelog commit
   (`chore: release vX.Y.Z`) and open/update a PR to `main` with that title and
   the changelog section as the body.

No loop: after a release PR merges, step 1 tags the new version; step 2 finds no
releasable commits since that fresh tag and does nothing.

## Flow

```
feature PR merges to main
  └─ release.yml: [1] v0.3.4 already tagged → no-op
                  [2] commits since v0.3.4 include feat → open/refresh
                       PR "chore: release v0.4.0" (Info.plist 0.3.4→0.4.0 + CHANGELOG)

release PR "chore: release v0.4.0" merges to main
  └─ release.yml: [1] Info.plist=0.4.0, tag v0.4.0 missing → create & push v0.4.0
                  [2] no releasable commits since v0.4.0 → no-op
```

## Migration / cutover

- Remove: `package.json`, `package-lock.json`, `.changeset/` (config, README, the
  two pending entries), `scripts/sync-version.js`, and the changesets
  `release.yml`.
- The two pending changeset entries (GuideModal, memory-churn) are already merged
  into `main`, so they are treated as **shipped in 0.3.4** and dropped. On its
  first run the workflow tags `v0.3.4` at current `main`; `0.4.0` is then driven
  by subsequent merges (the open timezone/focus/paste PRs).
- Keep the existing `CHANGELOG.md` (new sections prepend above it).

## Edge cases

- No tags yet → baseline = `Info.plist` version; step 1 creates `v0.3.4`.
- Only chore/docs/ci commits since last tag → no release PR.
- Re-runs are idempotent: `release/main` is force-updated; tag creation is
  guarded by existence check.
- A manual `Info.plist` bump merged outside the release PR would be tagged by
  step 1 on next push — documented as "bump only via the release PR".

## Testing

- `scripts/next-version.sh` and `prepare-release.sh` are run locally against the
  real repo history to confirm: correct next version, correct `Info.plist`
  rewrite, and correct grouped changelog. `Info.plist`/`CHANGELOG.md` edits are
  reverted after the local dry-run (the real bump happens via CI).
- `make build-dev` / `make test` remain green (no Swift changes).
