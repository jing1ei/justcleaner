import AppKit

enum SharePackager {

    enum Result {
        case success(String)
        case failure(String)
    }

    static let installerScript = """
    #!/bin/bash
    # Installs JustCleaner on this Mac. Nothing else is touched.
    set -u
    cd "$(dirname "$0")" || exit 1

    APP="JustCleaner.app"
    DEST="/Applications/JustCleaner.app"

    printf '\\nInstalling JustCleaner…\\n\\n'

    if [ ! -d "$APP" ]; then
      printf 'Cannot find JustCleaner.app next to this installer.\\n'
      printf 'Unzip the whole folder first, then run this again.\\n\\n'
      read -r -p 'Press return to close. ' _ || true
      exit 1
    fi

    INSTALL_PARENT="/Applications"
    STAGE="$(mktemp -d "$INSTALL_PARENT/.mactidy-install.XXXXXX" 2>/dev/null)" || {
      INSTALL_PARENT="$HOME/Applications"
      mkdir -p "$INSTALL_PARENT" || exit 1
      STAGE="$(mktemp -d "$INSTALL_PARENT/.mactidy-install.XXXXXX")" || exit 1
    }
    if ! ditto "$APP" "$STAGE/JustCleaner.app"; then
      rm -rf "$STAGE"
      printf 'Could not copy the app.\\n'
      exit 1
    fi
    DEST="$INSTALL_PARENT/JustCleaner.app"
    pkill -x JustCleaner 2>/dev/null || true
    pkill -x Beryl 2>/dev/null || true
    pkill -x MacTidy 2>/dev/null || true
    if [ -e "$DEST" ] && ! mv "$DEST" "$STAGE/previous.app"; then
      rm -rf "$STAGE"
      printf 'Could not replace the installed app.\\n'
      exit 1
    fi
    if ! mv "$STAGE/JustCleaner.app" "$DEST"; then
      [ ! -e "$STAGE/previous.app" ] || mv "$STAGE/previous.app" "$DEST"
      printf 'Install failed; staging files kept at %s\\n' "$STAGE"
      exit 1
    fi
    rm -rf "$STAGE"

    # macOS marks anything that arrived from another machine as untrusted
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

    if [ -f "$HOME/Library/LaunchAgents/com.mactidy.menubar.plist" ]; then
      "$DEST/Contents/MacOS/JustCleaner" login-item || printf 'Could not update start at login. Use JustCleaner Settings.\\n'
    fi
    open "$DEST" || { printf 'Could not launch JustCleaner.\\n'; exit 1; }

    printf 'Done.\\n\\n'
    printf 'Look for the sparkle icon in the menu bar, at the top right of the screen.\\n'
    printf 'Click it to see what can be cleaned on this Mac.\\n\\n'
    printf 'To start it automatically on every login: click the icon, then\\n'
    printf 'Settings > Start at login.\\n\\n'
    read -r -p 'Press return to close this window. ' _ || true
    """

    static let readme = """
    JustCleaner
    =======

    A quiet menu bar tool that finds throwaway files - caches, build leftovers,
    logs, old package downloads - explains what they are, and clears them with
    one click.

    To install on this Mac
    ----------------------
    1. Unzip this folder if it is still zipped.
    2. Double-click "Install JustCleaner.command".
       If macOS says it cannot be verified: right-click the file, choose Open,
       then confirm. That happens because the app is homemade rather than sold
       through the App Store.
    3. A sparkle icon appears in the menu bar. Click it.

    What it will never touch
    ------------------------
    Protected paths include ~/Music, recognized audio projects, plugins, sample libraries,
    preset and MIDI file. Personal folders are excluded from automatic cleanup;
    recognized project build folders can be reviewed separately when enabled.
    Known cloud folders are protected. Keys, passwords, Mail, Messages,
    Safari data and app settings. Source code of your own projects.

    Where it keeps things
    ---------------------
    Nothing is deleted where it lies. Removed items are moved to
    ~/.mactidy/quarantine first. Disposable caches may then be erased
    immediately; other files stay
    recoverable for a few days and can be put back from the menu.

    Settings:  ~/.mactidy/config.json
    Log:       ~/.mactidy/mactidy.log
    Report:    click "Open full report…" in the menu

    For the curious: the same program also works in Terminal.
      /Applications/JustCleaner.app/Contents/MacOS/JustCleaner scan
      /Applications/JustCleaner.app/Contents/MacOS/JustCleaner clean --dry-run
      /Applications/JustCleaner.app/Contents/MacOS/JustCleaner doctor
    """

    static func pack(destinationDir: String? = nil) -> Result {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app"), fm.fileExists(atPath: bundlePath) else {
            return .failure("JustCleaner is not running from an app bundle")
        }
        let desktop = destinationDir ?? (Paths.home + "/Desktop")
        let staging = NSTemporaryDirectory() + "JustCleaner-share-" + UUID().uuidString
        let folder = staging + "/JustCleaner"
        defer { try? fm.removeItem(atPath: staging) }
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            // a --to folder given on the command line may not exist yet
            try fm.createDirectory(atPath: desktop, withIntermediateDirectories: true)
            // ditto preserves symlinks, permissions and the code signature
            let copy = runCommand("/usr/bin/ditto", [bundlePath, folder + "/JustCleaner.app"],
                                  timeout: 120)
            guard copy.code == 0 else { return .failure("could not copy the app") }

            let script = folder + "/Install JustCleaner.command"
            try installerScript.write(toFile: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
            try readme.write(toFile: folder + "/Read me first.txt",
                             atomically: true, encoding: .utf8)

            let zipPath = desktop + "/JustCleaner-for-another-Mac.zip"
            let pendingZip = staging + "/share.zip"
            let zip = runCommand("/usr/bin/ditto",
                                 ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                  folder, pendingZip], timeout: 300)
            guard zip.code == 0, fm.fileExists(atPath: pendingZip) else {
                return .failure("could not create the zip file")
            }
            if fm.fileExists(atPath: zipPath) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: zipPath), withItemAt: URL(fileURLWithPath: pendingZip))
            } else {
                try fm.moveItem(atPath: pendingZip, toPath: zipPath)
            }
            appLog("packed for another Mac: " + zipPath)
            return .success(zipPath)
        } catch {
            return .failure((error as NSError).localizedDescription)
        }
    }
}
