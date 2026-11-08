# Cleanup and release audit — 2026-11-08

## Fixed

- Removed discovery of arbitrary assistant SQLite/DB files and JSONL indexes as
  history leftovers. Their records and WAL files are state, not disposable logs.
  Safety checks reject assistant databases/indexes even from stale reports and
  when nested inside a selected folder.
- Protected editor workspace/global storage, backups, file history, worktrees,
  JetBrains LocalHistory, and legacy `.mactidy` recovery data.
- Added explicit small-cache discovery (128 KiB threshold) for Codex, Claude,
  Cursor, VS Code, Windsurf, Trae, and Kiro. Existing generic rules remain for
  other tools. Settings, credentials, extensions and conversations are not
  included in the new disposable category.
- Separated Codex archived sessions into individual review-only findings,
  including small files. Archiving is reversible history, not deletion; see
  [Codex thread lifecycle documentation](https://learn.chatgpt.com/docs/app-server).
- Corrected running-owner recognition for Codex/Claude/VS Code/Cursor bundle
  names, JetBrains IDEs, and assistant caches under `.cache`. Node-hosted coding
  assistants conservatively block relevant cleanup while Node is running.
- Bumped the release to 1.1.0 so automatic publication does not overwrite 1.0.0.
  Main pushes build, test, checksum and publish through the existing release
  workflow; published versions remain immutable.

## Verification

The fixture-home Swift regression suite checks cleanup, recovery, symlink and
protected-content handling, process blocking, UI state, and the added developer
cleanup cases. Python tests exercise workflow version gates and release asset
verification/publication. No real user caches or sessions were deleted.

The local arm64 app builds and signs. This machine's Swift 6.4.2 toolchain lacks
x86_64 compatibility libraries; the release script correctly refuses to ship
its single-architecture output as universal. GitHub Actions uses macos-15 to
verify both architectures before publishing.

## Boundaries

This is a targeted code and regression audit, not proof against every filesystem
race or every IDE version. Process-name matching is conservative and cannot
identify every custom executable. Custom assistant homes are not explicitly
supported by the named rules. A cache containing protected state is skipped as a
whole. No blanket system temp sweep or deletion of unknown IDE database records
is attempted. Use each IDE's own controls for deleting database-backed chats.
The app remains ad-hoc signed and not notarized.
