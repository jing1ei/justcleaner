import Foundation

enum JustCleanerVersion {
    static let string = "1.1.1"
    static let bundleID = "com.justcleaner.menubar"
}

// What is actually installed on this Mac, in plain language. This is the half
// of the app that answers "what is going on in here", rather than "clean it".

struct ToolInfo: Codable {
    var name: String
    var path: String
    var realPath: String
    var origin: String
    var version: String
    var meaning: String
}

struct MusicSetup: Codable {
    struct PluginFolder: Codable {
        var path: String
        var label: String
        var count: Int
        var bytes: Int64
    }
    var apps: [String] = []
    var folders: [PluginFolder] = []
}

struct EnvironmentReport: Codable {
    var tools: [ToolInfo] = []
    var missing: [String] = []
    var duplicates: [String] = []
    var shellFiles: [String] = []
    var loginItems: [String] = []
    var music = MusicSetup()
    var collectedAt: Double = 0
}

extension EnvironmentReport {

    static let meanings: [(String, String)] = [
        ("brew", "Homebrew, the app store for command line tools"),
        ("node", "Node.js, runs JavaScript - needed by most AI-generated web projects"),
        ("npm", "npm, installs JavaScript libraries"),
        ("pnpm", "pnpm, a faster alternative to npm"),
        ("yarn", "Yarn, another alternative to npm"),
        ("python3", "Python, the language most AI scripts are written in"),
        ("uv", "uv, a fast modern Python installer"),
        ("pipx", "pipx, installs Python command line apps in isolation"),
        ("conda", "Conda, a heavyweight Python environment manager"),
        ("cargo", "Cargo, builds Rust projects"),
        ("rustup", "rustup, manages Rust compiler versions"),
        ("go", "Go, a programming language"),
        ("docker", "Docker, runs software in containers - can eat tens of gigabytes"),
        ("git", "Git, keeps the history of your projects"),
        ("swift", "Swift, Apple's language for Mac and iPhone apps"),
        ("deno", "Deno, a JavaScript runtime"),
        ("bun", "Bun, a very fast JavaScript runtime"),
        ("ollama", "Ollama, runs AI models locally"),
    ]

    static let originHints: [(String, String)] = [
        ("/opt/homebrew/", "installed by Homebrew"),
        ("/usr/local/bin/", "installed by an installer package, or by old Homebrew"),
        ("/usr/bin/", "shipped with macOS or Apple's command line tools"),
        ("/.cargo/bin/", "installed by rustup"),
        ("/.local/", "dropped into your home folder by a script or an AI tool"),
        ("/.nvm/", "installed by nvm, the Node version manager"),
        ("/.pyenv/", "installed by pyenv"),
        ("/.bun/", "installed by Bun"),
        ("/miniconda", "installed by Conda"),
        ("/anaconda", "installed by Conda"),
        ("/Applications/", "installed as a Mac app"),
    ]

    static func origin(_ path: String) -> String {
        for (fragment, label) in originHints where path.contains(fragment) {
            return label
        }
        return "unknown origin"
    }

    static func collect() -> EnvironmentReport {
        var report = EnvironmentReport()
        report.collectedAt = Date().timeIntervalSince1970

        for (name, meaning) in meanings {
            guard let path = realExecutable(name) else {
                report.missing.append(name)
                continue
            }
            let real = (URL(fileURLWithPath: path).resolvingSymlinksInPath()).path
            var version = ""
            // never run anything out of /usr/bin: some of those are stubs that
            // open an installer window, and a silent app must not do that
            if !path.hasPrefix("/usr/bin/") {
                let flag = name == "go" ? "version" : "--version"
                let r = runCommand(path, [flag], timeout: 6)
                if r.code == 0 {
                    version = firstVersionNumber(r.out)
                }
            }
            report.tools.append(ToolInfo(name: name, path: path, realPath: real,
                                         origin: origin(path.hasPrefix("/usr/bin/") ? path : real),
                                         version: version, meaning: meaning))
        }

        report.duplicates = duplicateTools()
        report.shellFiles = shellFiles()
        report.loginItems = loginItems()
        report.music = musicSetup()
        return report
    }

    static func firstVersionNumber(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        let pattern = try? NSRegularExpression(pattern: "[0-9]+\\.[0-9]+(\\.[0-9]+)?")
        let ns = line as NSString
        if let m = pattern?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: m.range)
        }
        return String(line.prefix(30))
    }

    /// The same command available from two places is the classic reason why a
    /// project "works in one window and not the other".
    static func duplicateTools() -> [String] {
        var out: [String] = []
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        var seenDirs: [String] = []
        for d in dirs where !d.isEmpty && !seenDirs.contains(d) { seenDirs.append(d) }
        for name in ["node", "npm", "python3", "cargo", "go", "brew", "git", "pnpm"] {
            var places: [String] = []
            for d in seenDirs {
                let candidate = d + "/" + name
                guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
                let real = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                if !places.contains(real) { places.append(real) }
            }
            if places.count > 1 {
                out.append("\(name): " + places.map(tildePath).joined(separator: "  and  "))
            }
        }
        return out
    }

    static func shellFiles() -> [String] {
        var out: [String] = []
        for name in [".zshrc", ".zprofile", ".zshenv", ".profile", ".bash_profile",
                     ".bashrc", ".bash_login"] {
            let path = Paths.home + "/" + name
            guard let data = try? FileSafety.readFile(path, limit: 1024 * 1024),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let pathEdits = lines.filter {
                let l = $0.trimmingCharacters(in: .whitespaces)
                return !l.hasPrefix("#") && l.contains("PATH=")
            }.count
            out.append("\(name): \(lines.count) lines, \(pathEdits) change(s) to PATH")
        }
        return out
    }

    static func loginItems() -> [String] {
        var out: [String] = []
        for root in [Paths.home + "/Library/LaunchAgents", "/Library/LaunchAgents"] {
            for name in Sizer.listDir(root) where name.hasSuffix(".plist") {
                out.append(name.replacingOccurrences(of: ".plist", with: "")
                           + (root.hasPrefix(Paths.home) ? " (yours)" : " (system-wide)"))
            }
        }
        return out
    }

    // ---- music: detected only so it can be declared untouchable ----------

    static let dawKeywords = [
        "logic pro", "garageband", "mainstage", "ableton live", "cubase",
        "nuendo", "pro tools", "studio one", "bitwig", "reaper", "fl studio",
        "reason", "luna", "maschine", "melodyne", "sibelius", "dorico",
        "musescore", "finale", "waveform", "ardour", "audacity", "serato",
        "rekordbox", "traktor", "izotope rx", "spectralayers", "digital performer",
        "sound forge", "wavelab", "hindenburg", "adobe audition",
    ]

    static func musicSetup() -> MusicSetup {
        var setup = MusicSetup()
        for folder in ["/Applications", Paths.home + "/Applications"] {
            for name in Sizer.listDir(folder) where name.hasSuffix(".app") {
                let low = name.lowercased()
                if dawKeywords.contains(where: { low.contains($0) }) {
                    let clean = String(name.dropLast(4))
                    if !setup.apps.contains(clean) { setup.apps.append(clean) }
                }
            }
        }
        let candidates: [(String, String)] = [
            ("/Library/Audio/Plug-Ins/VST3", "VST3 plugins"),
            ("/Library/Audio/Plug-Ins/VST", "VST2 plugins"),
            ("/Library/Audio/Plug-Ins/Components", "Audio Unit plugins"),
            ("/Library/Application Support/Avid/Audio/Plug-Ins", "AAX plugins for Pro Tools"),
            ("~/Library/Audio/Plug-Ins/VST3", "VST3 plugins, your user folder"),
            ("~/Library/Audio/Plug-Ins/VST", "VST2 plugins, your user folder"),
            ("~/Library/Audio/Plug-Ins/Components", "Audio Unit plugins, your user folder"),
            ("~/Music/Audio Music Apps", "Logic content, patches and presets"),
            ("~/Library/Application Support/Ableton", "Ableton Live library and preferences"),
            ("~/Library/Application Support/Native Instruments", "Native Instruments data"),
            ("/Library/Application Support/Native Instruments", "Native Instruments data"),
            ("/Library/Audio/Apple Loops", "Apple Loops sound library"),
            ("~/Library/Audio/Impulse Responses", "reverb impulse responses"),
            ("~/Library/Audio/MIDI Drivers", "MIDI drivers"),
            ("/Library/Audio/MIDI Drivers", "MIDI drivers"),
            ("~/Documents/Ableton", "your Ableton projects"),
            ("~/Music/Logic", "your Logic projects"),
        ]
        for (raw, label) in candidates {
            let path = Paths.expand(raw)
            guard Sizer.isDir(path) else { continue }
            let entries = Sizer.listDir(path).filter { !$0.hasPrefix(".") }
            let bytes = Sizer.measure(path, budget: 3.0)?.bytes ?? 0
            setup.folders.append(MusicSetup.PluginFolder(
                path: path, label: label, count: entries.count, bytes: bytes))
        }
        return setup
    }
}
