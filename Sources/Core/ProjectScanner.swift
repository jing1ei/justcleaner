import Foundation

struct RepoInfo: Codable {
    var path: String
    var bytes: Int64
    var mtime: Double
    var hasUnsavedWork: Bool?
}

enum ProjectScanner {

    static let pruneAlways = [
        "/library/", "/.trash", "/node_modules", "/cloudstorage", "/onedrive",
        "/dropbox", "/google drive", "/music/", "/movies/", "/pictures/",
        "/applications/", "/.mactidy", "/.git/", "/.venv/", "/site-packages/",
        "/photos library", "/mobile documents",
    ]

    static let interesting: [String: String] = [
        "node_modules": "downloaded JavaScript dependencies, re-installable with one command",
        "target": "Rust build output, rebuilt on demand",
        ".next": "Next.js build cache",
        ".nuxt": "Nuxt build cache",
        ".venv": "Python virtual environment, re-creatable",
        "venv": "Python virtual environment, re-creatable",
        "__pycache__": "compiled Python bytecode",
        ".pytest_cache": "test runner cache",
        ".mypy_cache": "type checker cache",
        ".ruff_cache": "linter cache",
        ".turbo": "Turborepo cache",
        ".parcel-cache": "Parcel bundler cache",
        ".vite": "Vite bundler cache",
        ".svelte-kit": "SvelteKit build cache",
        ".gradle": "Gradle project cache",
        ".dart_tool": "Flutter/Dart build cache",
        "Pods": "CocoaPods dependencies, re-installable",
        ".build": "Swift package build output, rebuilt by the next build",
        "DerivedData": "Xcode build output for this project",
        "cmake-build-debug": "CMake build output",
        "cmake-build-release": "CMake build output",
        ".expo": "Expo build cache",
        ".astro": "Astro build cache",
        ".docusaurus": "Docusaurus build cache",
        ".angular": "Angular build cache",
        ".tox": "Python test environments, re-creatable",
        ".stack-work": "Haskell build output",
        ".output": "build output, rebuilt on demand",
        "dist": "",      // generic: only counts next to a project manifest
        "build": "",
        "out": "",
        "vendor": "",
        ".cache": "",
    ]

    static let manifests = ["package.json", "Cargo.toml", "pyproject.toml",
                            "requirements.txt", "go.mod", "Podfile",
                            "pubspec.yaml", "vite.config.ts", "vite.config.js",
                            "next.config.js", "tsconfig.json", "Package.swift",
                            "CMakeLists.txt", "composer.json", "Gemfile",
                            "pom.xml", "build.gradle", "Makefile",
                            "stack.yaml"]

    /// Home folders that are never project roots.
    static let notProjectRoots: Set<String> = [
        "Library", "Music", "Pictures", "Movies", "Public", "Applications",
        "OneDrive", "Dropbox", "Google Drive", "Creative Cloud Files",
    ]

    static func roots(_ cfg: Config) -> [String] {
        var out: [String] = []
        for name in Sizer.listDir(Paths.home) {
            if name.hasPrefix(".") { continue }
            if notProjectRoots.contains(name) { continue }
            let personal = ["Desktop", "Documents", "Downloads"].contains(name)
            if personal && !cfg.scanPersonalFolders { continue }
            let p = Paths.home + "/" + name
            if Sizer.isDir(p) { out.append(p) }
        }
        return out
    }

    static func shouldPrune(_ path: String) -> Bool {
        let low = path.lowercased() + "/"
        return pruneAlways.contains { low.contains($0) }
    }

    static func hasManifest(_ dir: String) -> Bool {
        if manifests.contains(where: { Sizer.exists(dir + "/" + $0) }) { return true }
        // an Xcode project is a folder whose name ends in .xcodeproj
        return Sizer.listDir(dir).contains { $0.hasSuffix(".xcodeproj") }
    }

    struct Walk {
        var artifacts: [Finding] = []
        var repos: [RepoInfo] = []
    }

    /// One walk answers two questions (artifacts and repositories) and it is the
    /// slowest thing in the app, so the answer is kept for a quarter of an hour.
    /// The lock matters: the catalogue runs its rules on several threads at once.
    private static let cacheLock = NSLock()
    private static var cached: Walk?
    private static var cachedAt: Double = 0
    private static var cachedPersonal = false
    private static let cacheSeconds: Double = 900

    static func walk(_ cfg: Config, budget: Double = 45) -> Walk {
        cacheLock.lock()
        let hit = (cached != nil && cachedPersonal == cfg.scanPersonalFolders && nowTS() - cachedAt < cacheSeconds) ? cached : nil
        cacheLock.unlock()
        if let hit { return hit }

        var result = Walk()
        let started = Date()
        let fm = FileManager.default
        // A plain index instead of removeFirst(): shifting a few thousand
        // entries down by one, over and over, is a surprising amount of work.
        var queue: [(String, Int)] = roots(cfg).map { ($0, 0) }
        var next = 0
        let maxDepth = 6

        while next < queue.count {
            if Date().timeIntervalSince(started) > budget { break }
            let (dir, depth) = queue[next]
            next += 1
            if depth > maxDepth { continue }
            if shouldPrune(dir) { continue }

            let names = Sizer.listDir(dir)
            if names.contains(".git") {
                var info = RepoInfo(path: dir, bytes: 0, mtime: 0, hasUnsavedWork: nil)
                if let m = Sizer.measure(dir, budget: 2.0) {
                    info.bytes = m.bytes
                    info.mtime = m.newest
                }
                if let git = safeGitPath(),
                   Date().timeIntervalSince(started) < budget * 0.7 {
                    let r = runCommand(git, ["-C", dir, "status", "--porcelain"], timeout: 8)
                    if r.code == 0 { info.hasUnsavedWork = !r.out.isEmpty }
                }
                result.repos.append(info)
            }

            for name in names {
                let child = dir + "/" + name
                var isFolder = false
                var st = stat()
                if lstat(child, &st) == 0 {
                    if isLink(st) { continue }
                    isFolder = isDirectory(st)
                }
                guard isFolder else { continue }
                if let desc = interesting[name] {
                    var note = desc
                    if note.isEmpty {
                        // "dist", "build", "out" are only build output when the
                        // folder next to them is really a project
                        guard hasManifest(dir) else {
                            queue.append((child, depth + 1))
                            continue
                        }
                        note = "build output of this project, rebuilt on demand"
                    }
                    guard Safety.check(child, kind: .artifact).isOK else { continue }
                    if let m = Sizer.measure(child, budget: 4.0), m.bytes > 20 * 1024 * 1024 {
                        result.artifacts.append(Finding(
                            path: child, bytes: m.bytes, files: m.files,
                            mtime: m.newest,
                            note: note + ", last touched " + formatAge(m.newest),
                            partial: m.partial))
                    }
                    continue  // never walk into it
                }
                if name.hasPrefix("."), ![".github", ".config"].contains(name) {
                    continue
                }
                if !fm.isReadableFile(atPath: child) { continue }
                queue.append((child, depth + 1))
            }
        }
        result.artifacts.sort { $0.bytes > $1.bytes }
        result.repos.sort { $0.mtime > $1.mtime }
        cacheLock.lock()
        cached = result
        cachedPersonal = cfg.scanPersonalFolders
        cachedAt = nowTS()
        cacheLock.unlock()
        return result
    }

    static func scan(_ cfg: Config) -> [Finding] {
        walk(cfg).artifacts
    }

    static func repos(_ cfg: Config) -> [RepoInfo] {
        walk(cfg).repos
    }

    /// Throw the remembered walk away, so the next look really walks. Used when
    /// a setting changes what counts as a project folder, and when the human
    /// explicitly asks to look again.
    static func invalidate() {
        cacheLock.lock()
        cached = nil
        cachedAt = 0
        cacheLock.unlock()
    }
}
