import Foundation

enum ItemKind: String, Codable {
    /// Throwaway data inside a known cache location.
    case cache
    /// A dependency/build folder inside a coding project (node_modules, target).
    case artifact
    /// A cache/log folder found inside a dot-folder of a developer tool.
    case dotJunk
    /// Something we only ever report, never touch.
    case info
}

enum Safety {

    // ---- gate 1: never, ever, for any reason -----------------------------
    static let hardProtected: [String] = [
        // music production - the reason this Mac exists
        "/audio music apps", "/library/audio", "/audio/plug-ins", "/plug-ins/",
        "/vst", "/vst3", "/components/", "/aax", "/clap", "/audio units",
        "/logic", "logic pro", "/garageband", "/mainstage", "/ableton",
        "/live 1", "/cubase", "/nuendo", "/steinberg", "/pro tools", "/avid",
        "/studio one", "/presonus", "/bitwig", "/reaper", "/fl studio",
        "/image-line", "/luna", "/universal audio", "/reason", "/renoise",
        "/native instruments", "/komplete", "/kontakt", "/maschine",
        "/izotope", "/waves", "/fabfilter", "/xfer", "/serum", "/spectrasonics",
        "/arturia", "/u-he", "/valhalla", "/soundtoys", "/plugin alliance",
        "/spitfire", "/orchestral tools", "/vienna", "/east west", "/kilohearts",
        "/splice", "/loopcloud", "/output", "/baby audio", "/softube",
        "/melodyne", "/celemony", "/antares", "/slate digital", "/toontrack",
        "/superior drummer", "/ezdrummer", "/omnisphere", "/keyscape",
        "/sibelius", "/dorico", "/musescore", "/finale", "/notion",
        "/sample", "/samples", "/soundbank", "/sound library",
        "/impulse response", "/loops", "/presets", "/patches",
        "/midi", "/ilok", "/pace", "audiounitcache", "audiocomponent",
        "/music/",
        // irreplaceable personal data and secrets
        "photos library", "/library/cloudstorage/", "/onedrive", "/icloud", "/dropbox", "/google drive",
        "/library/mobile documents", "/library/keychains", "/library/messages",
        "/library/mail/", "/library/calendars", "/library/contacts",
        "/library/safari/", "/library/passwords", "/library/cookies",
        "/library/preferences/", "/library/application support/addressbook",
        "/library/group containers",
        "/.ssh", "/.gnupg", "/.aws", "/.config/gh", "/.netrc", "/.npmrc",
        "/.gitconfig", "credentials", "/keychain", "/auth.json", "/token",
        "/.git/objects", "/library/stickies",
        ".dmg", ".pkg",
    ]

    /// Blocks cache clean-up, but a recognised rebuildable build folder inside
    /// them may still be listed for the human to decide about.
    static let softProtected: [String] = [
        "/documents/", "/desktop/", "/pictures/", "/movies/", "/downloads/",
    ]

    // ---- gate 3: the only places ordinary junk may live ------------------
    static let allowedRoots: [String] = [
        "~/Library/Caches",
        "~/Library/Logs",
        "~/Library/Developer",
        "~/Library/Application Support",
        "~/Library/pnpm",
        "~/Library/Containers/com.apple.mail",
        "~/Library/WebKit",
        "~/.npm", "~/.cache", "~/.cargo", "~/.rustup", "~/.gradle", "~/.m2",
        "~/.bun", "~/.deno", "~/.swiftpm", "~/.pnpm-store", "~/.yarn",
        "~/.zsh_sessions", "~/.Trash", "~/.ollama", "~/.local",
    ].map(Paths.expand)

    /// Folders that must never be removed as a whole, however tempting.
    static let criticalExact: Set<String> = Set([
        "/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
        "/etc", "/var", "/opt", "/opt/homebrew", "/private", "/Users",
        Paths.home,
        "~/Library", "~/Library/Caches", "~/Library/Logs",
        "~/Library/Application Support", "~/Library/Developer",
        "~/Library/Containers", "~/Library/Preferences",
        "~/Documents", "~/Desktop", "~/Downloads", "~/Music", "~/Movies",
        "~/Pictures", "~/Public", "~/Library/Mobile Documents",
        "~/.Trash", "~/.cargo", "~/.rustup", "~/.npm", "~/.cache", "~/.config",
        "~/.local", "~/.ssh", "~/.codex", "~/.claude", "~/.cursor",
        Paths.stateDir,
    ].map(Paths.expand))

    /// Folders any build tool recreates from the project itself.
    static let regenerableDirNames: Set<String> = [
        "node_modules", "target", ".next", ".nuxt", "dist", "build", ".venv",
        "venv", "env", "__pycache__", ".pytest_cache", ".turbo",
        ".parcel-cache", "Pods", ".mypy_cache", ".ruff_cache", ".svelte-kit",
        ".angular", ".vite", "out", ".gradle", "vendor", ".tox", ".dart_tool",
        ".build", "DerivedData", "cmake-build-debug",
        "cmake-build-release", ".expo", ".astro", ".docusaurus", ".stack-work",
        ".output", ".cache",
    ]

    /// Subfolder names that are throwaway wherever a developer tool puts them.
    static let junkFolderNames: Set<String> = [
        "cache", "caches", "code cache", "codecache", "gpucache", "gpu cache",
        "logs", "log", "cacheddata", "cached data", "crashpad", "tmp", "temp",
        "dawncache", "dawngraphitecache", "dawnwebgpucache",
        "shadercache", "component_crx_cache", "cachedextensionvsixs",
        "codecachedata", "gputoolscache",
        "diskcache", "http cache", "networkcache", "imagecache",
        ".tmp", ".temp", ".cache", "tmpdir", "scratch", "thumbnails",
    ]

    enum Verdict {
        case ok
        case blocked(String)

        var isOK: Bool { if case .ok = self { return true }; return false }
        var reason: String {
            if case .blocked(let r) = self { return r }
            return ""
        }
    }

    /// Preserve editor recovery data and assistant state even from stale scan reports.
    static func isDeveloperState(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        if parts.contains(where: { ["workspacestorage", "globalstorage", "backups", "worktrees", "file-history", "localhistory", ".mactidy"].contains($0) }) { return true }
        guard parts.contains(where: { [".codex", ".claude", ".cursor"].contains($0) }),
              let name = parts.last else { return false }
        return name.contains(".sqlite") || name.hasSuffix(".db") || name.hasSuffix(".db-wal")
            || name.hasSuffix(".db-shm") || name == "session_index.jsonl"
    }

    static func check(_ path: String, kind: ItemKind) -> Verdict {
        if path.isEmpty || path.utf8.contains(0) { return .blocked("empty or invalid path") }
        if path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
            return .blocked("noncanonical path")
        }

        if isDeveloperState(path) { return .blocked("editor recovery data or assistant state") }
        guard !hasSymlinkComponent(path) else { return .blocked("symlink in path") }
        let norm = (path as NSString).standardizingPath
        if !norm.hasPrefix("/") { return .blocked("not an absolute path") }

        guard !hasSymlinkComponent(norm) else { return .blocked("symlink in path") }
        var isDir = false
        var st = stat()
        if lstat(norm, &st) == 0 {
            if isLink(st) { return .blocked("symlink") }
            isDir = isDirectory(st)
        }
        let low = norm.lowercased() + (isDir ? "/" : "")

        if criticalExact.contains(where: { $0.lowercased() == norm.lowercased() }) { return .blocked("critical folder") }
        if norm.lowercased() == Paths.stateDir.lowercased() || norm.lowercased().hasPrefix(Paths.stateDir.lowercased() + "/") {
            return .blocked("JustCleaner's own folder")
        }
        let depth = norm.filter { $0 == "/" }.count
        if depth < 3 && !norm.hasPrefix(Paths.home) {
            return .blocked("too close to the root of the disk")
        }

        for bad in hardProtected where low.contains(bad) {
            return .blocked("protected (" + trimmed(bad) + ")")
        }

        let homeDepth = Paths.home.filter { $0 == "/" }.count

        switch kind {
        case .info:
            // Information-only findings are listed in the report and in the
            // menu, and that is the whole of their life. There is no path that
            // reaches the disk for them.
            return .blocked("information only")

        case .artifact:
            let base = (norm as NSString).lastPathComponent
            if !regenerableDirNames.contains(base) {
                return .blocked("not a folder a build tool can recreate")
            }
            if !norm.hasPrefix(Paths.home + "/") {
                return .blocked("outside your home folder")
            }
            if low.contains("/library/") || low.contains("/.trash/") {
                return .blocked("inside a system folder")
            }
            if depth < homeDepth + 2 {
                return .blocked("not deep enough to be inside a project")
            }
            return .ok

        case .dotJunk:
            // ~/.sometool/Cache, ~/.sometool/foo/logs - the folder name itself
            // must be a known throwaway name, and it must sit inside a
            // dot-folder in the home directory.
            let base = (norm as NSString).lastPathComponent.lowercased()
            if !junkFolderNames.contains(base) {
                return .blocked("not a recognised cache or log folder")
            }
            guard norm.hasPrefix(Paths.home + "/.") else {
                return .blocked("not inside a tool's dot-folder")
            }
            if depth < homeDepth + 2 || depth > homeDepth + 4 {
                return .blocked("unexpected depth for a cache folder")
            }
            if let bad = softProtected.first(where: { low.contains($0) }) {
                return .blocked("protected (" + trimmed(bad) + ")")
            }
            return .ok

        case .cache:
            if let bad = softProtected.first(where: { low.contains($0) }) {
                return .blocked("protected (" + trimmed(bad) + ")")
            }
            for root in allowedRoots {
                if norm == root || norm.hasPrefix(root + "/") { return .ok }
            }
            // Shape rule, so that a tool this build has never heard of - but
            // which keeps its data in ~/.something, like every command line
            // tool does - is still reachable on your other Macs.
            if norm.hasPrefix(Paths.home + "/."), depth >= homeDepth + 2 {
                return .ok
            }
            return .blocked("outside the allowed area")
        }
    }

    static func hasSymlinkComponent(_ path: String) -> Bool {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            var st = stat()
            if lstat(current, &st) == 0, isLink(st) { return true }
        }
        return false
    }

    // A removable parent must not hide protected content. An incomplete walk
    // is not permission to remove an uninspected subtree.
    static func checkContents(_ path: String, budget: Double = 5, automatic: Bool = false) -> Verdict {
        let musicExtensions: Set<String> = ["wav", "aiff", "aif", "flac", "mp3", "m4a",
            "mid", "midi", "logicx", "band", "als", "rpp", "flp", "ptx", "song",
            "vst", "vst3", "component", "aaxplugin", "clap", "nki", "nkm", "sf2", "sfz"]
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else { return .blocked("content could not be checked") }
        let deadline = Date().addingTimeInterval(budget)
        var stack = [path]
        while let current = stack.popLast() {
            guard Date() < deadline else { return .blocked("content check timed out") }
            if isDeveloperState(current) { return .blocked("contains editor recovery data or assistant state") }
            if automatic && Catalog.requiresReview(current) { return .blocked("contains data requiring review") }
            let low = current.lowercased() + "/"
            if musicExtensions.contains((current as NSString).pathExtension.lowercased())
                || hardProtected.contains(where: { low.contains($0) }) {
                return .blocked("contains protected files")
            }
            var st = stat()
            guard lstat(current, &st) == 0 else { return .blocked("content could not be checked") }
            guard st.st_dev == rootStat.st_dev else { return .blocked("contains a mounted volume") }
            if !isDirectory(st) { continue }
            guard let dir = opendir(current) else { return .blocked("content could not be read") }
            while let entry = readdir(dir) {
                let name = Sizer.direntName(entry)
                if name != ".", name != ".." { stack.append(current + "/" + name) }
                if Date() >= deadline { closedir(dir); return .blocked("content check timed out") }
            }
            closedir(dir)
        }
        return .ok
    }

    private static func trimmed(_ pattern: String) -> String {
        pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Human readable checks for representative protected and allowed paths.
    static func selfTestCases() -> [(path: String, kind: ItemKind, mustBeAllowed: Bool)] {
        [
            (Paths.home + "/Music", .cache, false),
            (Paths.home + "/Music/Audio Music Apps", .cache, false),
            (Paths.home + "/Documents/song.logicx", .cache, false),
            (Paths.home + "/Documents", .cache, false),
            (Paths.home + "/Desktop", .cache, false),
            (Paths.home + "/Downloads", .cache, false),
            (Paths.home + "/Library", .cache, false),
            (Paths.home + "/Library/Caches", .cache, false),
            (Paths.home, .cache, false),
            ("/", .cache, false),
            ("/System/Library", .cache, false),
            ("/Library/Audio/Plug-Ins/VST3/Serum.vst3", .cache, false),
            ("/Library/Application Support/Avid/Audio/Plug-Ins", .cache, false),
            (Paths.home + "/Library/Audio/Plug-Ins/Components", .cache, false),
            (Paths.home + "/.ssh", .cache, false),
            (Paths.home + "/.ssh/id_rsa", .cache, false),
            (Paths.home + "/Library/Keychains", .cache, false),
            (Paths.home + "/Library/CloudStorage/OneDrive/x", .cache, false),
            (Paths.home + "/Pictures/Photos Library.photoslibrary", .cache, false),
            (Paths.stateDir + "/quarantine", .cache, false),
            (Paths.home + "/Library/Preferences/com.apple.dock.plist", .cache, false),
            (Paths.home + "/Music/proj/node_modules", .artifact, false),
            (Paths.home + "/Music/Ableton/proj/node_modules", .artifact, false),
            (Paths.home + "/Library/Caches/proj/node_modules", .artifact, false),
            (Paths.home + "/code/proj/src", .artifact, false),
            (Paths.home + "/.justcleaner/cache", .dotJunk, false),
            (Paths.home + "/.config/gh/cache", .dotJunk, false),
            // anything listed for information only can never reach the disk,
            // however ordinary the folder looks
            (Paths.home + "/Library/Caches/SomeApp", .info, false),
            // these must be allowed, otherwise the app cannot do its job
            (Paths.home + "/Library/Caches/pip", .cache, true),
            (Paths.home + "/Library/Caches/Google/Chrome", .cache, true),
            (Paths.home + "/Library/Developer/Xcode/DerivedData", .cache, true),
            (Paths.home + "/.npm/_cacache", .cache, true),
            (Paths.home + "/code/proj/node_modules", .artifact, true),
            (Paths.home + "/.cursor/Cache", .dotJunk, true),
            (Paths.home + "/.codex/logs", .dotJunk, true),
            // a build folder inside Documents or Desktop is still just a build
            // folder: it is listed under "needs your decision", never cleaned
            // automatically, and it is regenerable by definition
            (Paths.home + "/Documents/proj/node_modules", .artifact, true),
            (Paths.home + "/Desktop/proj/.venv", .artifact, true),
            (Paths.home + "/ParaphDev/Paraph/.build", .artifact, true),
        ]
    }
}
