# JustCleaner

<img src="assets/JustCleaner.png" alt="JustCleaner icon" width="128">

**Find removable caches. Clean what is ready. Restore retained files.**

A local macOS menu-bar utility for coding-tool caches, package downloads,
and app leftovers. **macOS 11+ · Apple silicon + Intel · No account**

## Install

From the source folder:

```bash
./build.sh --install
```

Requires Apple's Command Line Tools (`xcode-select --install`). The build
installs JustCleaner in `/Applications`, falling back to `~/Applications`, and opens
it. **Click the sparkle icon in the menu bar. There is no Dock window.**
The menu automatically follows macOS Light, Dark, or Auto appearance.

Have the packaged app? Unzip `JustCleaner-1.0.0-macOS-universal.zip`, then run
**Install JustCleaner.command**. The package needs no compiler. This local build is
ad-hoc signed, not notarized; use your Mac's normal approval flow if prompted.

## Use

| Step | Action | Result |
| --- | --- | --- |
| **Scan** | Open the menu; choose **Scan again** to refresh. | Estimated removable size, with running-app exclusions. |
| **Inspect** | Open a category or **Open full report…**. | Explanations and folder paths. Click a menu path to reveal it in Finder. |
| **Clean** | Choose **Clean up**. | Eligible files move to the safety net. Safe caches may then be erased. |
| **Restore** | Open **Safety net** and choose a dated batch. | Retained files return without overwriting existing files. |

**Prefer an undo window?** Turn off **Settings → Delete disposable caches
immediately** before cleaning. Retained files normally stay for 3 days; change
that duration in Settings. Moving files to the safety net does not free space
until they are erased.

### Cleanup at a glance

![Cleanup menu with available space, running-app exclusions, and categories](docs/screenshots/cleanup-menu.png)

### Recover retained files

Older batches remain under **Older cleanups**. **Empty safety net…** asks before
permanently removing retained files.

![Dated recovery batches and restore controls](docs/screenshots/recovery-menu.png)

### Understand every folder

The offline report has section links and expandable complete folder lists.

![Local report with explanations and expanded folder details](docs/screenshots/report.png)

*Screenshots show JustCleaner with illustrative sample data.*

## Safety and recovery

- Music, recognized audio projects/plugins, credentials, and protected paths
  are excluded. Personal folders are excluded from automatic cleanup;
  recognized project build folders there can be reviewed when enabled.
- Projects, assistant runtimes, models, and chat history require a separate
  decision. Running-app checks are a precaution, not proof a folder is unused.
- Immediately erased files, Trash, and Homebrew cleanup cannot be undone.
  Homebrew uses its own command outside the safety net.
- Interrupted, legacy, failed, and unlisted recovery data are kept for manual
  inspection. Cleanup and restore refuse cross-volume moves.
- Space values are estimates. APFS snapshots, shared blocks, hard links, and
  open files can delay reclaimed space. JustCleaner is not a backup system.

| If… | Do this |
| --- | --- |
| Caches are in use | Close the named app and scan again. |
| Restore needs attention | Choose **Show Retained Files**. Close the owning app and move any replacement folder somewhere safe before retrying. |
| Settings are damaged | **Settings → Reset settings…** saves the old file and restores defaults. Recovery data stays in place. |
| Folders are missing | Check project/personal-folder settings. Full Disk Access is optional and never bypasses safety rules. |
| An action fails | Read the menu feedback and **More → Open activity log…**. |

Use **Run deep scan…** to include projects, models, chat history, and Trash.
Export an installable copy through **More → Export app for another Mac…**.

To start at login, enable it in Settings. To uninstall, disable start at login,
quit JustCleaner, and move the app to Trash. Keep recovery files until no longer needed.

## Build and release

```bash
./build.sh       # build/JustCleaner.app
./Tests/run.sh   # isolated regression tests
./release.sh     # verified source ZIP, universal app ZIP, SHA256SUMS in dist/
```

`./sync.sh` updates the local installer/source files in `site/`; it does not
publish them. `Sources/App/` contains the interface and CLI; `Sources/Core/`
contains scanning, safety, cleanup, persistence, and reports.

```bash
./build/JustCleaner.app/Contents/MacOS/JustCleaner scan
./build/JustCleaner.app/Contents/MacOS/JustCleaner clean --dry-run
./build/JustCleaner.app/Contents/MacOS/JustCleaner report --open
./build/JustCleaner.app/Contents/MacOS/JustCleaner help
```

Noninteractive cleaning requires `--yes`. No shell alias is installed.

State remains in `~/.mactidy/` for compatibility: settings, last scan, activity
log, reports, and quarantine. The bundle identifier is also stable. Screenshots
and their [provenance](docs/screenshots/README.md) ship with the source.

## GitHub automation

Pushes and pull requests run tests, build the universal macOS app, and save
ZIPs and checksums in the Actions run. Manual runs are available from Actions.

To publish a release, set `JustCleanerVersion.string` in
`Sources/Core/Environment.swift`, commit it, and push a matching tag:

```bash
git push origin HEAD
git tag v1.0.0
git push origin v1.0.0
```

The tag must match the app version. After checks pass, GitHub publishes the app
ZIP, source ZIP, and `SHA256SUMS`. Published tags are not overwritten. A failed
upload leaves a draft that a rerun can finish. Reruns use the exact artifact
produced by their successful build; assets are verified again before publishing.
Use a new version for later releases.

Enable GitHub Actions in the repository. No personal token is needed: the
publishing job uses GitHub's built-in token with `contents: write`. Repository
or organization policy must allow that permission. These builds are ad-hoc
signed; the workflow does not perform Apple notarization.

Workflow shell paths can be checked locally with `python3 Tests/workflow.py`.

## Distribution

The release script verifies both architectures and the code signature. For
public distribution, sign with your Developer ID, notarize, and staple the app
before packaging. A locally signed build does not provide notarization or
stable permission grants across rebuilds.

Validation here covers local regression tests and compilation for both
architectures. Actual macOS 11 execution, login/logout, TCC denial, and
power-loss behavior need testing in a disposable Mac or VM before broad rollout.

## Automatic downloads

Every successful build from a push to `main` refreshes the public **1.0.0** release.
All required platform builds and checks must pass first. Downloads use
`App-1.0.0-OS-architecture.ext`, such as `App-1.0.0-macOS-universal.zip`
or `App-1.0.0-Windows-x64.exe`. See [release automation](.github/RELEASES.md)
for the exact packages, checksums, and retry behavior.
