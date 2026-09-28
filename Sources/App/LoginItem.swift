import AppKit

// "Start when I log in", done the boring, portable way: a LaunchAgent file.
// It works identically on every macOS version from Big Sur onwards, needs no
// entitlement, no helper tool and no administrator password, and you can see
// and delete it yourself: ~/Library/LaunchAgents/com.mactidy.menubar.plist

enum LoginItem {

    static var plistPath: String {
        Paths.home + "/Library/LaunchAgents/" + JustCleanerVersion.bundleID + ".plist"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    @discardableResult
    static func enable() -> Bool {
        let dir = (plistPath as NSString).deletingLastPathComponent
        do { try FileSafety.createDirectory(dir) } catch { return false }
        let plist: [String: Any] = [
            "Label": JustCleanerVersion.bundleID,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return false }
        do {
            try FileSafety.writeJournal(data, to: plistPath)
        } catch {
            return false
        }
        appLog("login item enabled -> " + executablePath)
        return true
    }

    @discardableResult
    static func disable() -> Bool {
        // LaunchAgents are loaded at the next login. Removing the file changes
        // that preference without terminating the app handling this click.
        do {
            if isEnabled { try FileManager.default.removeItem(atPath: plistPath) }
            appLog("login item disabled")
            return true
        } catch { return false }
    }
}
