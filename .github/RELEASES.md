# Automatic releases

Every push and pull request runs the **build** job: the regression suite, the
release-tooling tests, and the universal macOS build. The verified packages are
saved as workflow artifacts. Pull requests and branch pushes never publish.

## What publishes, and when

A **release** is published by the **publish** job, which only runs on:

- a push to `main`, or
- a push of a version tag of the form `vX.Y.Z`.

The release version is read from a single source of truth,
`JustCleanerVersion.string` in `Sources/Core/Environment.swift`. A version tag
must match it exactly (`1.2.3` in code, tag `v1.2.3`), or the build fails.

## Versions are immutable

A published release is never moved or overwritten:

- the tag is never force-updated to another commit;
- an already published `vX.Y.Z` at a different commit fails the run instead of
  replacing the release;
- re-running the workflow for the exact same published commit is an idempotent
  no-op;
- to ship changes, bump `JustCleanerVersion.string` and push the new tag.

## Publication is all-or-nothing

The publisher (` .github/scripts/release.py`) only receives `contents: write`
and, before anything becomes public:

1. requires both packages and the build-produced `SHA256SUMS` to be present and
   to verify locally;
2. creates or updates the release as a **draft**;
3. uploads `JustCleaner-<version>-macOS-universal.zip`,
   `JustCleaner-<version>-source.zip`, and `SHA256SUMS.txt`;
4. downloads every uploaded asset through the API and re-checks its SHA-256;
5. only then creates the tag (if absent) and flips the draft to published.

Any checksum, asset, or tag mismatch aborts with the release still in draft, so
a failed run can be fixed and re-run without users ever seeing a bad asset.

## Required packages

For version `X.Y.Z`:

- `JustCleaner-X.Y.Z-macOS-universal.zip` — universal app plus the
  `Install JustCleaner.command` installer;
- `JustCleaner-X.Y.Z-source.zip` — complete source;
- `SHA256SUMS.txt` — SHA-256 of every attached asset.

These builds are ad-hoc signed and are not notarized. For public distribution
outside your own GitHub, sign with a Developer ID, notarize, and staple before
packaging (see the README "Distribution" section).

## Running it locally

```bash
python3 Tests/workflow.py                 # workflow shell steps
JC_VERSION=1.0.0 python3 .github/scripts/test_release.py
```
