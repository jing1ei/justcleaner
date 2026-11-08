import Foundation

// Runs the catalogue, in parallel, with a time budget, and remembers the answer
// so that opening the menu is instant.

struct DiskSnapshot: Codable {
    var total: Int64
    var free: Int64
    var used: Int64
}

struct ScanResult: Codable {
    var version: Int = 2
    var machine: String = Paths.machineName
    var user: String = NSUserName()
    var mode: String = "quick"
    var startedAt: Double = 0
    var finishedAt: Double = 0
    var categories: [CategoryResult] = []
    var disk: DiskSnapshot? = nil
    var quarantineBytes: Int64 = 0
    var homebrewFreeableBytes: Int64 = 0
    var warnings: [String] = []
    var repos: [RepoInfo] = []
    var environment: EnvironmentReport? = nil
    /// Junk that belongs to an app that was running when the scan finished.
    /// Counted in cleanableBytes, but one click will not touch it.
    var blockedBytes: Int64 = 0
    var blockedApps: [String] = []

    /// What the one-click button will deal with.
    var cleanableBytes: Int64 {
        categories.filter { $0.risk == .safe || $0.risk == .slower }
                  .reduce(0) { $0 + $1.bytes } + homebrewFreeableBytes
    }

    /// Estimated eligible bytes, excluding caches held by recognized open apps.
    var readyBytes: Int64 { max(cleanableBytes - blockedBytes, 0) }

    /// "quit Lark and Codex to free another 6.5 GB"
    var blockedSentence: String? {
        guard blockedBytes > 0, !blockedApps.isEmpty else { return nil }
        if blockedApps.contains("Process status unavailable") {
            return "Could not check running apps. Scan again before cleaning."
        }
        let apps: String
        if blockedApps.count == 1 { apps = blockedApps[0] }
        else if blockedApps.count == 2 { apps = blockedApps.joined(separator: " and ") }
        else { apps = blockedApps.prefix(2).joined(separator: ", ") + " and others" }
        return "Close \(apps) to clean another \(human(blockedBytes))"
    }

    /// Big things you decide about, and that JustCleaner can move for you once you
    /// say so. The Trash is deliberately not in here: it is not moved, it is
    /// emptied, and only by an explicit click.
    var reviewBytes: Int64 {
        categories.filter { $0.risk == .review && $0.kind != .info }
                  .reduce(0) { $0 + $1.bytes }
    }

    var trashBytes: Int64 { category("trash")?.bytes ?? 0 }

    /// Everything the menu files under "Needs your decision".
    var decisionBytes: Int64 { reviewBytes + trashBytes }

    var infoBytes: Int64 {
        categories.filter { $0.risk == .info }.reduce(0) { $0 + $1.bytes }
    }

    var isDeep: Bool { mode == "deep" }

    func category(_ id: String) -> CategoryResult? {
        categories.first { $0.id == id }
    }

    var ageDescription: String {
        guard finishedAt > 0 else { return "never" }
        let minutes = (Date().timeIntervalSince1970 - finishedAt) / 60
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(Int(minutes)) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(Int(hours)) h ago" }
        return "\(Int(hours / 24)) days ago"
    }
}

enum JunkScanner {

    private static let scanLock = NSLock()

    static func loadLast() -> ScanResult? {
        guard let data = try? FileSafety.readFile(Paths.lastScanFile, limit: 32 * 1024 * 1024),
              let r = try? JSONDecoder().decode(ScanResult.self, from: data)
        else { return nil }
        guard r.startedAt.isFinite, r.finishedAt.isFinite,
              r.startedAt >= 0, r.finishedAt >= 0, r.finishedAt <= nowTS() + 300,
              r.quarantineBytes >= 0, r.homebrewFreeableBytes >= 0, r.blockedBytes >= 0 else { return nil }
        var total = r.homebrewFreeableBytes
        for category in r.categories {
            for item in category.items {
                let (next, overflow) = total.addingReportingOverflow(item.bytes)
                guard item.bytes >= 0, item.files >= 0, item.mtime.isFinite, item.mtime >= 0,
                      !overflow, item.path.hasPrefix("/"), !item.path.utf8.contains(0) else { return nil }
                total = next
            }
        }
        if let disk = r.disk {
            guard disk.total > 0, disk.free >= 0, disk.free <= disk.total,
                  disk.used >= 0, disk.used <= disk.total else { return nil }
        }
        return r
    }

    static func save(_ result: ScanResult) {
        guard Paths.ensureStateDirs() else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(result), data.count <= 32 * 1024 * 1024 {
            try? FileSafety.writeJournal(data, to: Paths.lastScanFile)
        }
    }

    /// deep = also look inside projects, list the your-call items and read the
    /// development environment. Quick = caches only, a couple of seconds.
    static func scan(deep: Bool, cfg: Config, progress: ((String) -> Void)? = nil) -> ScanResult {
        scanLock.lock()
        defer { scanLock.unlock() }

        var result = ScanResult()
        result.mode = deep ? "deep" : "quick"
        result.startedAt = Date().timeIntervalSince1970

        let specs = Catalog.specs.filter { deep || !$0.deep }
        var found = [CategoryResult?](repeating: nil, count: specs.count)
        let resultLock = NSLock()
        var completed = 0
        var refused = 0

        DispatchQueue.concurrentPerform(iterations: specs.count) { index in
            let spec = specs[index]
            let items = spec.finder(cfg)
            var cat = CategoryResult(id: spec.id, group: spec.group,
                                     title: spec.title, what: spec.what,
                                     risk: spec.risk, kind: spec.kind)
            // Everything that will ever be offered for removal is validated
            // here, once, before a human can even see it.
            cat.items = items.filter { item in
                spec.kind == .info || ((spec.risk == .review || !Catalog.requiresReview(item.path))
                    && Catalog.enabled(item.path, cfg: cfg)
                    && Safety.check(item.path, kind: spec.kind).isOK
                    && Safety.checkContents(item.path, automatic: spec.risk != .review).isOK)
            }
            resultLock.lock()
            found[index] = cat
            refused += items.count - cat.items.count
            completed += 1
            progress?("\(completed) of \(specs.count) categories checked")
            resultLock.unlock()
        }

        result.categories = dedupe(found.compactMap { $0 })
            .filter { !$0.items.isEmpty }
            .sorted { $0.bytes > $1.bytes }

        if let d = Sizer.diskInfo() {
            result.disk = DiskSnapshot(total: d.total, free: d.free, used: d.used)
        }
        result.quarantineBytes = Quarantine.totalBytes()
        if cfg.includeHomebrewCleanup {
            progress?("Checking Homebrew leftovers")
            result.homebrewFreeableBytes = Homebrew.freeableBytes()
        }
        result.warnings = warnings()
        if let issue = Config.loadIssue { result.warnings.append(issue) }
        if refused > 0 {
            result.warnings.append("\(refused) candidate(s) were excluded by preferences or safety checks. Excluded files are not included in cleanup totals.")
        }
        if deep {
            result.repos = cfg.scanProjects ? Array(ProjectScanner.repos(cfg).prefix(40)) : []
            progress?("Reading the development environment")
            result.environment = EnvironmentReport.collect()
        } else if let previous = loadLast() {
            // A quick look does not walk your projects, so rather than dropping
            // what the last deep look found, carry it over - but only the parts
            // that are still on disk, so the menu never offers a folder that
            // has already gone.
            result.repos = cfg.scanProjects ? previous.repos.filter { Sizer.isDir($0.path) } : []
            result.environment = previous.environment
            for old in previous.categories where old.risk == .review || old.risk == .info {
                guard result.category(old.id) == nil, old.id != "project-builds" || cfg.scanProjects else { continue }
                var carried = old
                carried.items = old.items.filter {
                    Sizer.exists($0.path) && Catalog.enabled($0.path, cfg: cfg)
                        && (cfg.scanPersonalFolders || !["/Desktop/", "/Documents/", "/Downloads/"].contains(where: $0.path.contains))
                }
                if !carried.items.isEmpty { result.categories.append(carried) }
            }
            result.categories = dedupe(result.categories).filter { !$0.items.isEmpty }.sorted { $0.bytes > $1.bytes }
        }
        result.finishedAt = Date().timeIntervalSince1970
        // Work out, once, how much of that a single click can really free with
        // the apps that are open right now - so the menu never promises 11 GB
        // and then delivers 4.
        let preview = Cleaner.plan(result, respectRunningApps: true,
                                   processes: Cleaner.runningProcessNames())
        result.blockedBytes = preview.blockedBytes
        result.blockedApps = preview.blockedByApp.map { $0.app }
        save(result)
        appLog("scan \(result.mode) took \(Int(result.finishedAt - result.startedAt))s, "
               + "cleanable \(human(result.cleanableBytes)) "
               + "(ready \(human(result.readyBytes)))")
        return result
    }

    static func dedupe(_ cats: [CategoryResult]) -> [CategoryResult] {
        let priorities = Catalog.priorities
        struct Candidate {
            let cat: Int
            let item: Finding
            let depth: Int
            let priority: Int
        }
        // A wider automatic rule must never subsume data requiring consent,
        // including when it matches exactly the same path.
        let reviewPaths = cats.filter { $0.risk == .review && $0.kind != .info }
            .flatMap { $0.items.map { $0.path.lowercased() } }
        var candidates: [Candidate] = []
        for (i, cat) in cats.enumerated() {
            // information-only rows are never cleaned, so overlap is harmless
            // and even useful there ("this is where the disk went").
            guard cat.kind != .info, cat.risk != .info else { continue }
            let p = priorities[cat.id] ?? 50
            for item in cat.items {
                if cat.risk != .review, reviewPaths.contains(where: {
                    $0 == item.path.lowercased() || $0.hasPrefix(item.path.lowercased() + "/")
                }) { continue }
                candidates.append(Candidate(cat: i, item: item,
                                            depth: item.path.filter { $0 == "/" }.count,
                                            priority: p))
            }
        }
        // outermost first; ties broken by the more specific rule, then by size
        candidates.sort {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.item.bytes > $1.item.bytes
        }

        var kept = Set<String>()
        var keptPerCategory = [Int: [Finding]]()
        var dropped = 0
        var droppedBytes: Int64 = 0
        for c in candidates {
            let path = c.item.path
            // Because the list is sorted outermost first, any folder that
            // contains this one has already been decided. Walking up the path is
            // a handful of string operations; comparing against everything kept
            // so far would be quadratic.
            if kept.contains(path) || hasKeptAncestor(of: path, in: kept) {
                dropped += 1
                droppedBytes += c.item.bytes
                continue
            }
            kept.insert(path)
            keptPerCategory[c.cat, default: []].append(c.item)
        }
        if dropped > 0 {
            appLog("dedupe removed \(dropped) overlapping items (\(human(droppedBytes)))")
        }

        var out = cats
        for (i, cat) in cats.enumerated() {
            guard cat.kind != .info, cat.risk != .info else { continue }
            var copy = cat
            copy.items = (keptPerCategory[i] ?? []).sorted { $0.bytes > $1.bytes }
            out[i] = copy
        }
        return out
    }

    private static func hasKeptAncestor(of path: String, in kept: Set<String>) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if kept.contains(parent) { return true }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }

    static func warnings() -> [String] {
        var out: [String] = []
        let blocked = ["~/Library/Caches", "~/Library/Logs", "~/Library/Application Support"]
            .map(Paths.expand)
            .filter { Sizer.isDir($0) && opendirFails($0) }
        if !blocked.isEmpty {
            out.append("macOS denied access to some scan locations, so totals may be incomplete. To allow measurement, add JustCleaner under System "
                       + "Settings > Privacy & Security > Full Disk Access.")
        }
        return out
    }

    private static func opendirFails(_ path: String) -> Bool {
        guard let d = opendir(path) else { return true }
        closedir(d)
        return false
    }
}

enum Homebrew {
    static var brewPath: String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return findExecutable("brew")
    }

    /// Asks Homebrew how much it could tidy up itself, without doing anything.
    static func freeableBytes() -> Int64 {
        guard let brew = brewPath else { return 0 }
        let r = runCommand(brew, ["cleanup", "-n"], timeout: 60)
        guard r.code == 0 else { return 0 }
        return parseSize(r.out)
    }

    static func cleanup() -> (ok: Bool, output: String) {
        guard let brew = brewPath else { return (false, "Homebrew is not installed") }
        let r = runCommand(brew, ["cleanup"], timeout: 600)
        return (r.code == 0, r.out)
    }

    static func parseSize(_ text: String) -> Int64 {
        // "==> This operation would free approximately 1.2GB of disk space."
        guard let range = text.range(of: "approximately ") else { return 0 }
        let tail = text[range.upperBound...]
        let scanner = Scanner(string: String(tail))
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = (scanner.scanCharacters(from: CharacterSet.letters) ?? "MB").uppercased()
        let multiplier: Double
        switch unit.prefix(1) {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        let bytes = value * multiplier
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return 0 }
        return Int64(bytes)
    }
}
