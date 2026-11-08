import Foundation

enum Risk: String, Codable {
    case safe      // disposable caches and logs
    case slower    // safe, but the tool re-downloads something next time
    case review    // your call: possibly big, possibly wanted
    case info      // never touched, listed so you know where the disk went

    var label: String {
        switch self {
        case .safe: return "Safe"
        case .slower: return "Safe, slower next time"
        case .review: return "Your call"
        case .info: return "Information only"
        }
    }
}

struct Finding: Codable {
    var path: String
    var bytes: Int64
    var files: Int
    var mtime: Double
    var note: String
    var partial: Bool = false
}

struct CategoryResult: Codable {
    var id: String
    var group: String
    var title: String
    var what: String
    var risk: Risk
    var kind: ItemKind
    var items: [Finding] = []
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

struct CategorySpec {
    var id: String
    var group: String
    var title: String
    var what: String
    var risk: Risk
    var kind: ItemKind = .cache
    /// Deep categories are skipped by the fast background scan.
    var deep: Bool = false
    /// When two rules find the same folder, the lower number keeps it - so the
    /// row you see is the one with the most specific explanation. Overlapping
    /// parent/child folders are resolved in Scanner.dedupe(), which is what
    /// stops the same gigabyte from being counted twice.
    var priority: Int = 50
    var finder: (Config) -> [Finding]
}

enum Catalog {

    static func enabled(_ path: String, cfg: Config) -> Bool {
        if cfg.includeHomebrewCleanup && path.lowercased().contains("/caches/homebrew") { return false }
        if cfg.includeBrowserCaches { return true }
        let low = path.lowercased()
        return !["/google", "chrome", "chromium", "safari", "webkit", "firefox", "edgemac",
                 "microsoft edge", "thebrowser", "/arc/", "brave", "opera", "vivaldi"]
            .contains(where: { low.contains($0) })
    }

    /// Reserved review data stays out of broad cache rules in quick scans too.
    static func requiresReview(_ path: String) -> Bool {
        let components = path.lowercased().split(separator: "/").map(String.init)
        let names: Set<String> = ["huggingface", "torch", "whisper", "lm-studio", "models", "runtimes", "runtime", "sessions", "archived_sessions", "deleted_sessions", "chats",
                                  "projects", "worktrees", "backups", "workspacestorage",
                                  "globalstorage", "history", "file-history", "shell-snapshots"]
        return components.contains { names.contains($0) || $0.hasSuffix("-runtimes")
            || $0.hasSuffix(".sqlite") || $0.hasSuffix(".sqlite-wal")
            || $0.hasSuffix(".sqlite-shm") || $0.hasSuffix(".db") }
    }

    // ---- shared helpers --------------------------------------------------

    static func items(_ pairs: [(String, String)],
                      minBytes: Int64 = 512 * 1024,
                      olderThanDays: Double = 0,
                      budget: Double = 5.0) -> [Finding] {
        var out: [Finding] = []
        var seen = Set<String>()
        for (raw, note) in pairs {
            let path = Paths.expand(raw)
            if seen.contains(path) { continue }
            seen.insert(path)
            guard Sizer.exists(path), let m = Sizer.measure(path, budget: budget) else { continue }
            if m.bytes < minBytes { continue }
            if olderThanDays > 0, let age = daysAgo(m.newest), age < olderThanDays { continue }
            out.append(Finding(path: path, bytes: m.bytes, files: m.files,
                               mtime: m.newest, note: note, partial: m.partial || m.denied))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static func children(of parentRaw: String,
                         minBytes: Int64 = 20 * 1024 * 1024,
                         olderThanDays: Double = 0,
                         excludeContaining: [String] = [],
                         noteMaker: ((String, Measurement) -> String)? = nil,
                         budget: Double = 2.0,
                         limit: Int = 500) -> [Finding] {
        let parent = Paths.expand(parentRaw)
        guard Sizer.isDir(parent) else { return [] }
        var out: [Finding] = []
        for name in Sizer.listDir(parent).prefix(limit) {
            let low = name.lowercased()
            if excludeContaining.contains(where: { low.contains($0) }) { continue }
            let path = parent + "/" + name
            guard let m = Sizer.measure(path, budget: budget), m.bytes >= minBytes else { continue }
            if olderThanDays > 0, let age = daysAgo(m.newest), age < olderThanDays { continue }
            let note = noteMaker?(name, m) ?? ("last used " + formatAge(m.newest))
            out.append(Finding(path: path, bytes: m.bytes, files: m.files,
                               mtime: m.newest, note: note, partial: m.partial || m.denied))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Music and audio words. Anything matching is never even measured.
    static let audioWords = [
        "audio", "music", "logic", "ableton", "midi", "vst", "plugin", "plug-in",
        "kontakt", "native instruments", "izotope", "waves", "steinberg",
        "arturia", "spitfire", "splice", "fabfilter", "melodyne", "avid",
        "presonus", "bitwig", "reaper", "toontrack", "spectrasonics", "sibelius",
        "dorico", "musescore", "celemony", "ilok", "pace", "softube", "u-he",
        "serum", "xfer", "output", "loopcloud", "sample", "soundtoys",
    ]

    static let privateWords = [
        "keychain", "icloud", "cloudkit", "photos", "mail", "safari",
        "com.apple.appstore", "com.apple.aned", "com.apple.akd",
        "com.apple.containermanagerd", "com.apple.security", "passwords",
        "com.apple.bird", "mobile documents", "group containers",
    ]

    // ---- named rules -----------------------------------------------------

    static func packageCaches(_ cfg: Config) -> [Finding] {
        items([
            ("~/.npm/_cacache", "downloaded copies of JavaScript packages"),
            ("~/.npm/_npx", "tools that were run once via npx"),
            ("~/.npm/_logs", "npm error logs"),
            ("~/Library/Caches/pip", "downloaded copies of Python packages"),
            ("~/.cache/pip", "downloaded copies of Python packages"),
            ("~/Library/Caches/uv", "uv (Python installer) download cache"),
            ("~/.cache/uv", "uv (Python installer) download cache"),
            ("~/Library/Caches/Yarn", "Yarn package download cache"),
            ("~/Library/pnpm/store", "pnpm package store"),
            ("~/.pnpm-store", "pnpm package store"),
            ("~/.bun/install/cache", "Bun package download cache"),
            ("~/.cache/deno", "Deno dependency cache"),
            ("~/.cargo/registry/cache", "compressed Rust package downloads"),
            ("~/.cargo/registry/src", "unpacked Rust package sources"),
            ("~/.cargo/git/checkouts", "Rust dependencies pulled from git"),
            ("~/.cargo/git/db", "Rust git dependency database"),
            ("~/Library/Caches/go-build", "Go compiler cache"),
            ("~/.cache/go-build", "Go compiler cache"),
            ("~/.gradle/caches", "Gradle (Java/Android) download cache"),
            ("~/.m2/repository", "Maven (Java) download cache"),
            ("~/Library/Caches/org.swift.swiftpm", "Swift package cache"),
            ("~/.swiftpm/cache", "Swift package cache"),
            ("~/Library/Caches/CocoaPods", "CocoaPods (iOS) download cache"),
            ("~/Library/Caches/Homebrew", "Homebrew's downloaded installers"),
            ("~/Library/Caches/ms-playwright", "browsers downloaded for testing"),
            ("~/Library/Caches/puppeteer", "browsers downloaded for testing"),
            ("~/Library/Caches/node-gyp", "Node build headers"),
            ("~/Library/Caches/electron", "downloaded Electron runtimes"),
            ("~/Library/Caches/typescript", "TypeScript definitions cache"),
            ("~/Library/Caches/deno", "Deno cache"),
            ("~/.cache/yarn", "Yarn package download cache"),
            ("~/.cache/bun", "Bun cache"),
            ("~/.cache/turbo", "Turborepo remote cache"),
            ("~/.cache/pre-commit", "pre-commit tool environments"),
            ("~/.cache/puppeteer", "browsers downloaded for testing"),
            ("~/.cache/ms-playwright", "browsers downloaded for testing"),
            ("~/.cache/node-gyp", "Node build headers"),
            ("~/.cache/typescript", "TypeScript definitions cache"),
            ("~/.cache/electron", "downloaded Electron runtimes"),
        ])
        // plus anything else in ~/.cache that is plainly a build cache
        + children(of: "~/.cache", minBytes: 10 * 1024 * 1024,
                   excludeContaining: audioWords + [
                       "hugging", "torch", "whisper", "model", "ollama", "lm-studio",
                       "pip", "uv", "deno", "go-build", "yarn", "bun", "turbo",
                       "pre-commit", "puppeteer", "playwright", "node-gyp",
                       "typescript", "electron", "runtimes",
                   ],
                   noteMaker: { name, m in
                       "cache of the \(name) tool, last used " + formatAge(m.newest)
                   })
    }

    static func xcodeJunk(_ cfg: Config) -> [Finding] {
        items([
            ("~/Library/Developer/Xcode/DerivedData", "build leftovers from Mac/iOS projects"),
            ("~/Library/Developer/CoreSimulator/Caches", "iPhone simulator caches"),
            ("~/Library/Developer/Xcode/iOS DeviceSupport", "debug files for iPhones you once plugged in"),
            ("~/Library/Developer/Xcode/watchOS DeviceSupport", "debug files for Apple Watches"),
            ("~/Library/Developer/Xcode/tvOS DeviceSupport", "debug files for Apple TVs"),
            ("~/Library/Caches/com.apple.dt.Xcode", "Xcode's own cache"),
            ("~/Library/Developer/CoreSimulator/Temp", "temporary simulator files"),
        ])
    }

    /// Shape rule: cache and log folders inside any tool's dot-folder.
    static func dotFolderJunk(_ cfg: Config) -> [Finding] {
        var pairs: [(String, String)] = []
        let skip: Set<String> = [
            ".Trash", ".justcleaner", ".mactidy", ".ssh", ".gnupg", ".aws", ".config", ".git", ".cache",
            ".Trashes", ".DocumentRevisions-V100", ".TemporaryItems",
        ]
        for name in Sizer.listDir(Paths.home) where name.hasPrefix(".") {
            if skip.contains(name) { continue }
            let base = Paths.home + "/" + name
            guard Sizer.isDir(base) else { continue }
            let tool = String(name.dropFirst())
            for level1 in Sizer.listDir(base) {
                let p1 = base + "/" + level1
                guard Sizer.isDir(p1) else { continue }
                if Safety.junkFolderNames.contains(level1.lowercased()) {
                    pairs.append((p1, "cache or log folder of \(tool)"))
                    continue
                }
                for level2 in Sizer.listDir(p1) {
                    let p2 = p1 + "/" + level2
                    if Safety.junkFolderNames.contains(level2.lowercased()),
                       Sizer.isDir(p2) {
                        pairs.append((p2, "cache or log folder of \(tool)"))
                    }
                }
            }
        }
        return items(pairs, minBytes: 2 * 1024 * 1024, budget: 2.0)
    }

    /// Shape rule: cache folders inside ~/Library/Application Support.
    /// Covers every Electron app - editors, chat apps, AI tools - including the
    /// ones installed only on your other Macs.
    static func appSupportCaches(_ cfg: Config) -> [Finding] {
        let root = Paths.expand("~/Library/Application Support")
        var pairs: [(String, String)] = []
        for app in Sizer.listDir(root) {
            let low = app.lowercased()
            if audioWords.contains(where: { low.contains($0) }) { continue }
            if privateWords.contains(where: { low.contains($0) }) { continue }
            let appDir = root + "/" + app
            guard Sizer.isDir(appDir) else { continue }
            for sub in Sizer.listDir(appDir) {
                let subPath = appDir + "/" + sub
                if Safety.junkFolderNames.contains(sub.lowercased()), Sizer.isDir(subPath) {
                    pairs.append((subPath, "\(app) rebuilds this by itself"))
                }
            }
            // one level deeper: Chromium profiles, "Service Worker/CacheStorage"
            for profile in ["Default", "Profile 1", "Profile 2", "Service Worker"] {
                let pdir = appDir + "/" + profile
                guard Sizer.isDir(pdir) else { continue }
                for sub in Sizer.listDir(pdir) {
                    let subPath = pdir + "/" + sub
                    if Safety.junkFolderNames.contains(sub.lowercased()), Sizer.isDir(subPath) {
                        pairs.append((subPath, "\(app) rebuilds this by itself"))
                    }
                }
            }
        }
        return items(pairs, minBytes: 5 * 1024 * 1024, budget: 2.0)
    }

    static func browserCaches(_ cfg: Config) -> [Finding] {
        guard cfg.includeBrowserCaches else { return [] }
        var pairs: [(String, String)] = []
        let cacheRoot = "~/Library/Caches/"
        for (name, label) in [
            ("com.apple.Safari", "Safari"),
            ("com.apple.Safari.SafeBrowsing", "Safari"),
            ("com.apple.WebKit.WebContent", "Safari page"),
            ("Google/Chrome", "Chrome"),
            ("com.google.Chrome", "Chrome"),
            ("com.google.Chrome.helper", "Chrome"),
            ("com.microsoft.edgemac", "Edge"),
            ("company.thebrowser.Browser", "Arc"),
            ("com.brave.Browser", "Brave"),
            ("Firefox", "Firefox"),
            ("com.operasoftware.Opera", "Opera"),
            ("com.vivaldi.Vivaldi", "Vivaldi"),
            ("org.mozilla.firefox", "Firefox"),
        ] {
            pairs.append((cacheRoot + name,
                          "\(label) web cache - pages re-download, you stay logged in"))
        }
        return items(pairs, minBytes: 1024 * 1024, budget: 3.0)
    }

    static func systemAppCaches(_ cfg: Config) -> [Finding] {
        children(of: "~/Library/Caches",
                 minBytes: 20 * 1024 * 1024,
                 excludeContaining: audioWords + privateWords + ["homebrew"],
                 noteMaker: { name, m in
                     let owner = prettyOwner(name)
                     if let age = daysAgo(m.newest), age >= 30 {
                         return "cache of \(owner), untouched since " + formatAge(m.newest)
                     }
                     return "cache of \(owner), rebuilt automatically when needed"
                 },
                 budget: 2.5)
    }

    /// Installers an app already used, and half-finished downloads of its own
    /// updates. Apps keep these forever; they re-download if they ever need to.
    static func updaterLeftovers(_ cfg: Config) -> [Finding] {
        let updaterNames: Set<String> = [
            "update", "updates", "updater", "pending_update", "pendingupdate",
            "shipit", "squirrelupdate", "sparkleupdater", "autoupdate",
            "installer", "installers",
        ]
        var pairs: [(String, String)] = []
        for rootRaw in ["~/Library/Application Support", "~/Library/Caches"] {
            let root = Paths.expand(rootRaw)
            for app in Sizer.listDir(root) {
                let low = app.lowercased()
                if audioWords.contains(where: { low.contains($0) }) { continue }
                if privateWords.contains(where: { low.contains($0) }) { continue }
                let appDir = root + "/" + app
                guard Sizer.isDir(appDir) else { continue }
                // an app whose own name says "updater": all of it is leftovers
                if low.hasSuffix("-updater") || low.hasSuffix("updater")
                    || low.hasSuffix("-update") {
                    pairs.append((appDir,
                                  "installers \(prettyOwner(app)) downloaded for itself"))
                    continue
                }
                for sub in Sizer.listDir(appDir) where updaterNames.contains(sub.lowercased()) {
                    let p = appDir + "/" + sub
                    guard Sizer.isDir(p) else { continue }
                    pairs.append((p, "installers \(prettyOwner(app)) already used - "
                                   + "it downloads a new one when there is an update"))
                }
            }
        }
        return items(pairs, minBytes: 20 * 1024 * 1024, budget: 3.0)
    }

    /// "LarkShell" -> "Lark", "com.apple.helpd" -> "Help Viewer"-ish. Only used
    /// for wording, never for deciding anything.
    static func prettyOwner(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("com.") {
            let parts = name.split(separator: ".")
            if parts.count >= 3 { name = String(parts[2]) }
        }
        for suffix in ["Shell", "Helper", "-helper"] where name.hasSuffix(suffix) && name.count > suffix.count + 2 {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    static func logsAndCrashes(_ cfg: Config) -> [Finding] {
        items([
            ("~/Library/Logs/DiagnosticReports", "crash reports from apps that quit unexpectedly"),
            ("~/Library/Logs/CoreSimulator", "iPhone simulator logs"),
            ("~/Library/Logs/JetBrains", "JetBrains IDE logs"),
        ], minBytes: 128 * 1024)
        + children(of: "~/Library/Logs",
                   minBytes: 5 * 1024 * 1024,
                   olderThanDays: 14,
                   excludeContaining: audioWords + ["diagnosticreports"],
                   noteMaker: { name, m in
                       "log folder of \(name), nothing new since " + formatAge(m.newest)
                   },
                   budget: 2.0)
    }

    static func miscSystem(_ cfg: Config) -> [Finding] {
        items([
            ("~/Library/Caches/com.apple.QuickLook.thumbnailcache",
             "Finder preview thumbnails"),
            ("~/Library/Caches/com.apple.helpd", "macOS help viewer cache"),
            ("~/Library/Caches/com.apple.iBooksX", "Books app cache"),
            ("~/Library/Caches/com.apple.appstore", "App Store download cache"),
            ("~/Library/Caches/com.apple.Spotlight", "Spotlight helper cache"),
            ("~/.zsh_sessions", "saved Terminal window sessions"),
            ("~/Library/Caches/com.apple.python", "Python bytecode cache"),
        ], minBytes: 512 * 1024)
    }

    // ---- your-call rules -------------------------------------------------

    static func projectBuilds(_ cfg: Config) -> [Finding] {
        guard cfg.scanProjects else { return [] }
        return ProjectScanner.scan(cfg)
    }

    static func agentRuntimes(_ cfg: Config) -> [Finding] {
        var pairs: [(String, String)] = [
            ("~/.cache/codex-runtimes", "a private copy of Node/Python an AI assistant downloaded for itself"),
            ("~/.cache/aime-runtimes", "a private copy of Node/Python an AI assistant downloaded for itself"),
            ("~/.local/node-lts-cache", "a private copy of Node an AI assistant downloaded"),
        ]
        for base in [".trae", ".trae-cn", ".agents", ".cursor", ".claude",
                     ".codex", ".windsurf", ".aime_pc", ".agentbuddy", ".kiro"] {
            let tool = String(base.dropFirst())
            pairs.append(("~/\(base)/runtimes",
                          "a private copy of Node or Python that \(tool) downloaded for itself"))
        }
        for name in Sizer.listDir(Paths.expand("~/.cache")) {
            let low = name.lowercased()
            if low.hasSuffix("-runtimes") || low.hasSuffix("runtime") || low == "node" {
                pairs.append(("~/.cache/" + name, "a private copy of a programming language"))
            }
        }
        return items(pairs, minBytes: 10 * 1024 * 1024, budget: 6.0)
    }

    static func aiModels(_ cfg: Config) -> [Finding] {
        items([
            ("~/.cache/huggingface", "AI models downloaded from Hugging Face"),
            ("~/.cache/torch", "AI models downloaded by PyTorch"),
            ("~/.cache/whisper", "speech recognition models"),
            ("~/.cache/lm-studio", "local AI models (LM Studio)"),
            ("~/.ollama/models", "local AI models (Ollama)"),
            ("~/Library/Application Support/nomic.ai", "local AI models (GPT4All)"),
            ("~/Library/Caches/lm-studio", "local AI model cache"),
        ], minBytes: 50 * 1024 * 1024, budget: 6.0)
    }

    /// Explicit disposable locations; never infer that a session or database is junk.
    static func developerCaches(_ cfg: Config) -> [Finding] {
        var pairs: [(String, String)] = [
            ("~/.codex/log", "Codex diagnostic logs"),
            ("~/.codex/tmp", "Codex temporary files; close Codex before cleaning"),
            ("~/.claude/debug", "Claude Code diagnostic logs"),
            ("~/.claude/cache", "Claude Code disposable cache"),
        ]
        for app in ["Code", "Code - Insiders", "Cursor", "Windsurf", "Codex", "Claude", "Trae", "Kiro"] {
            for folder in ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs", "logs", "Crashpad", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache"] {
                pairs.append(("~/Library/Application Support/\(app)/\(folder)", "\(app) cache or diagnostics; rebuilt when needed"))
            }
        }
        return items(pairs, minBytes: 128 * 1024, budget: 2.0)
    }

    static func archivedSessions(_ cfg: Config) -> [Finding] {
        // Archived is not deleted: offer individual files only with explicit review.
        children(of: "~/.codex/archived_sessions", minBytes: 1,
                 noteMaker: { _, m in "Archived Codex conversation; removing it loses resume history (" + formatAge(m.newest) + ")" })
    }

    static func aiHistory(_ cfg: Config) -> [Finding] {
        var pairs: [(String, String)] = [
            ("~/.codex/sessions", "transcripts of your past AI coding chats"),
            ("~/.codex/history.jsonl", "the list of prompts you typed"),
            ("~/.claude/projects", "transcripts of your past AI coding chats"),
            ("~/.cursor/chats", "transcripts of your past AI coding chats"),
            ("~/.aider.chat.history.md", "transcripts of your past AI coding chats"),
        ]
        for base in [".codex", ".claude", ".cursor", ".trae", ".trae-cn",
                     ".agents", ".aime_pc", ".agentbuddy"] {
            let dir = Paths.expand("~/" + base)
            guard Sizer.isDir(dir) else { continue }
            for name in Sizer.listDir(dir) {
                let low = name.lowercased()
                if low.hasSuffix(".log")
                    || low == "visualizations" || low == "screenshots"
                    || low == "computer-use" || low == "attachments" {
                    pairs.append((dir + "/" + name,
                                  "files the \(base.dropFirst()) assistant produced or logged"))
                }
            }
        }
        return items(pairs, minBytes: 20 * 1024 * 1024, budget: 5.0)
    }

    static func trash(_ cfg: Config) -> [Finding] {
        items([("~/.Trash", "files you already deleted but never emptied")],
              minBytes: 1024 * 1024, budget: 8.0)
    }

    static func bigThings(_ cfg: Config) -> [Finding] {
        var pairs: [(String, String)] = [
            ("~/Library/Application Support/MobileSync/Backup", "full backups of an iPhone or iPad"),
            ("~/Library/Developer/CoreSimulator/Devices", "iPhone simulators created by Xcode"),
            ("~/Library/Containers/com.docker.docker/Data/vms", "the Docker virtual machine"),
            ("~/.docker", "Docker's own data"),
            ("~/.rustup/toolchains", "installed Rust compiler versions"),
            ("~/.local", "command line tools installed into your home folder"),
            ("~/.nvm", "Node versions installed by nvm"),
            ("~/.pyenv", "Python versions installed by pyenv"),
            ("~/miniconda3", "a Conda Python installation"),
            ("~/anaconda3", "a Conda Python installation"),
            ("~/Library/Caches/com.apple.amp.itmsappledevice", "device support files"),
        ]
        if cfg.scanPersonalFolders {
            pairs += [("~/Downloads", "your Downloads folder"),
                      ("~/Desktop", "your Desktop")]
        }
        return items(pairs, minBytes: 200 * 1024 * 1024, budget: 8.0)
    }

    // ---- the catalogue ---------------------------------------------------

    static let specs: [CategorySpec] = [
        CategorySpec(
            id: "package-caches", group: "Developer caches",
            title: "Package download caches",
            what: "Downloaded dependencies and package caches. Tools may download them again.",
            risk: .safe, priority: 10, finder: packageCaches),
        CategorySpec(
            id: "xcode", group: "Developer caches",
            title: "Xcode and Swift build leftovers",
            what: "Xcode and Swift build caches. The next build may take longer.",
            risk: .slower, priority: 10, finder: xcodeJunk),
        CategorySpec(
            id: "developer-caches", group: "Developer caches",
            title: "Editor and coding assistant caches",
            what: "Disposable Codex, Claude, Cursor, VS Code and other editor caches and diagnostics. Close the tool before cleaning.",
            risk: .safe, priority: 5, finder: developerCaches),
        CategorySpec(
            id: "ai-tools", group: "Developer caches",
            title: "Caches and logs of coding and AI tools",
            what: "Cache and log folders used by coding assistants. Settings and chat history are excluded.",
            risk: .safe, kind: .dotJunk, priority: 15, finder: dotFolderJunk),
        CategorySpec(
            id: "app-caches", group: "App and system caches",
            title: "Cache folders inside app data",
            what: "Temporary app caches. The app may rebuild them when next opened.",
            risk: .safe, priority: 20, finder: appSupportCaches),
        CategorySpec(
            id: "browser-caches", group: "App and system caches",
            title: "Browser caches",
            what: "Cached web images and scripts. Bookmarks, history, and login data are excluded.",
            risk: .safe, priority: 20, finder: browserCaches),
        CategorySpec(
            id: "updater-leftovers", group: "App and system caches",
            title: "Installers apps downloaded for their own updates",
            what: "Downloaded app updates. The app may download them again.",
            risk: .slower, priority: 25, finder: updaterLeftovers),
        CategorySpec(
            id: "logs", group: "App and system caches",
            title: "Old logs and crash reports",
            what: "Diagnostic logs and crash reports. Keep them if you are investigating a problem.",
            risk: .safe, priority: 25, finder: logsAndCrashes),
        CategorySpec(
            id: "misc", group: "App and system caches",
            title: "Miscellaneous macOS caches",
            what: "Finder thumbnails, saved Terminal sessions, and macOS download caches.",
            risk: .slower, priority: 30, finder: miscSystem),
        CategorySpec(
            id: "library-caches", group: "App and system caches",
            title: "App caches macOS keeps in your Library",
            what: "App caches in your Library. Recognized running apps and protected paths are skipped.",
            risk: .slower, priority: 60, finder: systemAppCaches),
        CategorySpec(
            id: "project-builds", group: "Needs your decision",
            title: "Dependency and build folders inside projects",
            what: "Dependencies and build output. Confirm they are reproducible before removing; the project may need a reinstall or rebuild.",
            risk: .review, kind: .artifact, deep: true, priority: 40, finder: projectBuilds),
        CategorySpec(
            id: "agent-runtimes", group: "Needs your decision",
            title: "Private language copies downloaded by AI assistants",
            what: "Language runtimes used by coding assistants. Removing them may require a download or disrupt the assistant.",
            risk: .review, deep: true, priority: 40, finder: agentRuntimes),
        CategorySpec(
            id: "ai-models", group: "Needs your decision",
            title: "Downloaded AI models",
            what: "Downloaded AI models. Keep models you use or cannot easily download again.",
            risk: .review, deep: true, priority: 40, finder: aiModels),
        CategorySpec(
            id: "archived-sessions", group: "Needs your decision",
            title: "Archived Codex sessions",
            what: "Archived conversations are recoverable history, not temporary files. Review each file before removing it.",
            risk: .review, deep: true, priority: 40, finder: archivedSessions),
        CategorySpec(
            id: "ai-history", group: "Needs your decision",
            title: "AI chat transcripts and assistant leftovers",
            what: "Saved assistant conversations and related files. Review before removing; they may not be replaceable.",
            risk: .review, deep: true, priority: 45, finder: aiHistory),
        CategorySpec(
            id: "trash", group: "Needs your decision",
            title: "Trash",
            what: "Files you placed in Trash. Emptying Trash permanently deletes them.",
            risk: .review, kind: .info, deep: true, priority: 90, finder: trash),
        CategorySpec(
            id: "big-things", group: "Storage overview",
            title: "Large folders, information only",
            what: "Large folders for reference only. JustCleaner does not remove them.",
            risk: .info, kind: .info, deep: true, priority: 99, finder: bigThings),
    ]

    static var priorities: [String: Int] {
        var out: [String: Int] = [:]
        for s in specs { out[s.id] = s.priority }
        return out
    }

    static func spec(_ id: String) -> CategorySpec? {
        specs.first { $0.id == id }
    }
}
