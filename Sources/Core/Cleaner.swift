import Foundation

struct QuarantineEntry: Codable {
    var src: String
    var dst: String
    var bytes: Int64
    var category: String
    var risk: String?
}

struct QuarantineManifest: Codable {
    var created: String
    var keep_days: Double
    var moved: [QuarantineEntry] = []
    var failed: [[String: String]] = []
    var bytes: Int64 = 0
    var freed_immediately: Int64 = 0
    var machine: String? = Paths.machineName
    var app_version: String? = JustCleanerVersion.string
    // Missing/false means legacy or interrupted: require manual inspection.
    var completed: Bool? = false
    var created_at: Double? = nowTS()
}

struct Batch {
    var name: String
    var path: String
    var bytes: Int64
    var manifest: QuarantineManifest?
    var createdAt: Double
    var isRestorable: Bool { !(manifest?.moved.isEmpty ?? true) }
}

enum Quarantine {

    static func batches(measure: Bool = true) -> [Batch] {
        guard Sizer.isDir(Paths.quarantineDir) else { return [] }
        var out: [Batch] = []
        for name in Sizer.listDir(Paths.quarantineDir).reversed() {
            let path = Paths.quarantineDir + "/" + name
            guard Sizer.isDir(path) else { continue }
            let manifest = readManifest(path)
            var st = stat()
            let created = manifest?.created_at ?? (lstat(path, &st) == 0 ? Double(st.st_birthtimespec.tv_sec) : 0)
            let size = measure ? (Sizer.measure(path, budget: 3.0)?.bytes ?? 0)
                : (manifest?.moved.reduce(Int64(0)) { $0 + $1.bytes } ?? 0)
            out.append(Batch(name: name, path: path, bytes: size,
                             manifest: manifest, createdAt: created))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    static func readManifest(_ path: String) -> QuarantineManifest? {
        guard let data = try? FileSafety.readFile(path + "/manifest.json", limit: 16 * 1024 * 1024) else { return nil }
        guard let manifest = try? JSONDecoder().decode(QuarantineManifest.self, from: data),
              manifest.keep_days.isFinite, manifest.keep_days >= 0,
              manifest.bytes >= 0, manifest.freed_immediately >= 0,
              manifest.created_at.map({ $0.isFinite && $0 >= 0 && $0 <= nowTS() + 300 }) ?? true else { return nil }
        var total: Int64 = 0
        for entry in manifest.moved {
            let (next, overflow) = total.addingReportingOverflow(entry.bytes)
            guard entry.bytes >= 0, !overflow,
                  (try? FileSafety.validateFilePath(entry.src)) != nil,
                  (try? FileSafety.validateFilePath(entry.dst)) != nil,
                  entry.src.hasPrefix(Paths.home + "/"), entry.dst == path + entry.src,
                  !entry.src.utf8.contains(0), !entry.dst.utf8.contains(0) else { return nil }
            total = next
        }
        return manifest
    }

    /// Files outside recorded destinations may be user-added recovery material.
    /// Automatic expiry must not treat them as part of a completed cleanup.
    static func hasOnlyRecordedContent(_ batch: String, manifest: QuarantineManifest) -> Bool {
        let destinations = Set(manifest.moved.map { $0.dst })
        guard destinations.allSatisfy({ $0.hasPrefix(batch + "/") && !$0.utf8.contains(0) }) else { return false }
        var stack = [batch]
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while let current = stack.popLast() {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: current) else { return false }
            for name in names {
                let child = current + "/" + name
                if child == batch + "/manifest.json" || destinations.contains(child) { continue }
                guard Sizer.isDir(child), destinations.contains(where: { $0.hasPrefix(child + "/") }) else { return false }
                stack.append(child)
            }
        }
        return true
    }

    static func totalBytes() -> Int64 {
        Sizer.measure(Paths.quarantineDir, budget: 4.0)?.bytes ?? 0
    }

    static func restore(_ batch: Batch) -> (restored: Int, failed: Int) {
        guard let operation = DiskOperation(requiresValidConfig: false), validBatchPath(batch.path),
              var manifest = readManifest(batch.path) else { return (0, 1) }
        let entries = manifest.moved
        // A restored or partially restored batch requires inspection before expiry.
        manifest.completed = false
        defer { operation.finish() }
        guard Cleaner.writeManifest(manifest, to: batch.path) else { return (0, 1) }
        var ok = 0, bad = 0
        var remaining: [QuarantineEntry] = []
        let fm = FileManager.default
        let shallowestFirst = entries.sorted {
            $0.src.split(separator: "/").count < $1.src.split(separator: "/").count
        }
        for e in shallowestFirst {
            guard !e.src.utf8.contains(0), !e.dst.utf8.contains(0),
                  e.src == (e.src as NSString).standardizingPath,
                  e.src.hasPrefix(Paths.home + "/"),
                  e.src.lowercased() != Paths.stateDir.lowercased(),
                  !e.src.lowercased().hasPrefix(Paths.stateDir.lowercased() + "/"),
                  e.dst == batch.path + e.src,
                  !Safety.hasSymlinkComponent(e.src),
                  !Safety.hasSymlinkComponent(e.dst) else {
                bad += 1; remaining.append(e); continue
            }
            guard Sizer.exists(e.dst) else {
                // A missing source is not proof that recovery succeeded.
                if !Sizer.exists(e.src) { bad += 1; remaining.append(e) }
                continue
            }
            do {
                try FileSafety.createDirectory((e.src as NSString).deletingLastPathComponent)
                if Sizer.exists(e.src) {
                    bad += 1
                    remaining.append(e)
                    continue
                }
                try FileSafety.move(e.dst, to: e.src)
                ok += 1
            } catch {
                bad += 1
                remaining.append(e)
            }
        }
        manifest.moved = remaining
        if !Cleaner.writeManifest(manifest, to: batch.path) { bad += 1 }
        if bad == 0 {
            // Remove only empty scaffolding. Unlisted content keeps the batch.
            _ = FileSafety.pruneEmptyDirectories(batch.path)
            let names = Sizer.listDir(batch.path)
            if names == ["manifest.json"] {
                do {
                    try fm.removeItem(atPath: batch.path + "/manifest.json")
                    if rmdir(batch.path) != 0 { bad += 1 }
                } catch { bad += 1 }
            } else { bad += 1 }
        }
        ProjectScanner.invalidate()
        appLog("undo \(batch.name): restored \(ok), failed \(bad)")
        return (ok, bad)
    }

    static func purge(olderThanDays days: Double) -> RemovalOutcome {
        guard days.isFinite, days >= 0, let operation = DiskOperation() else {
            return RemovalOutcome(failed: 1)
        }
        defer { operation.finish() }
        var result = RemovalOutcome()
        for batch in batches() {
            guard validBatchPath(batch.path), let manifest = readManifest(batch.path),
                  manifest.completed == true, manifest.failed.isEmpty,
                  hasOnlyRecordedContent(batch.path, manifest: manifest),
                  let age = daysAgo(batch.createdAt), age >= days else { continue }
            let bytes = deleteBatchUnlocked(batch)
            if Sizer.exists(batch.path) { result.failed += 1 }
            else { result.bytes = addBytes(result.bytes, bytes); result.removed += 1 }
        }
        return result
    }

    static func purgeAll() -> RemovalOutcome {
        guard let operation = DiskOperation() else { return RemovalOutcome(failed: 1) }
        defer { operation.finish() }
        var result = RemovalOutcome()
        for batch in batches() {
            guard validBatchPath(batch.path) else { result.failed += 1; continue }
            let bytes = deleteBatchUnlocked(batch)
            if Sizer.exists(batch.path) { result.failed += 1 }
            else { result.bytes += bytes; result.removed += 1 }
        }
        return result
    }

    static func validBatchPath(_ path: String) -> Bool {
        path == (path as NSString).standardizingPath
            && (path as NSString).deletingLastPathComponent == Paths.quarantineDir
            && !Safety.hasSymlinkComponent(path)
    }

    private static func deleteBatchUnlocked(_ b: Batch) -> Int64 {
        // Refuse deletion outside the safety net.
        let norm = (b.path as NSString).standardizingPath
        guard norm.hasPrefix(Paths.quarantineDir + "/") else { return 0 }
        let size = Sizer.measure(norm, budget: 3)?.bytes ?? 0
        do {
            try FileSafety.removeTree(norm)
            appLog("purged \(b.name), freed \(human(size))")
            // This is the moment the disk actually gets the space back, so this
            // is the moment the running total is allowed to grow.
            if size > 0 {
                if !Config.recordFreed(size) { appLog("Could not save cleanup statistics") }
            }
            return size
        } catch {
            return 0
        }
    }
}

struct CleanPlanItem {
    var path: String
    var bytes: Int64
    var kind: ItemKind
    var category: String
    var categoryTitle: String
    var risk: Risk
}

struct CleanOutcome {
    var movedBytes: Int64 = 0
    var freedNowBytes: Int64 = 0
    var parkedBytes: Int64 = 0
    var itemCount: Int = 0
    var failedCount: Int = 0
    var brewFreedBytes: Int64 = 0
    var batchName: String = ""
    var skippedBecauseRunning: [String] = []
}

/// What one click would actually do, and what it deliberately would not.
struct CleanPlan {
    var items: [CleanPlanItem] = []
    /// Junk that exists, is safe in principle, but belongs to an app that is
    /// open at this second. Never yanked from under a running app.
    var blockedByApp: [(app: String, bytes: Int64)] = []

    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var blockedBytes: Int64 { blockedByApp.reduce(0) { $0 + $1.bytes } }

    /// Plain sentences for the summary sheet and the Terminal.
    var skipped: [String] {
        blockedByApp.map {
            "\($0.app) is running - \(human($0.bytes)) of its cache left alone "
            + "(close it and clean again to get that too)"
        }
    }
}

enum Cleaner {

    /// Apps that own a whole category. If one of them is running the category is
    /// left alone: removing a cache from under a live app is how you corrupt
    /// something. Categories not listed here are checked path by path instead,
    /// see ownerToken() below.
    static let liveAppHints: [String: [String]] = [
        "agent-runtimes": ["Cursor", "Trae", "Codex", "Aime", "Claude", "Windsurf"],
        "ai-history": ["Cursor", "Trae", "Codex", "Aime", "Claude"],
        "xcode": ["Xcode"],
    ]

    static func runningProcessNames() -> Set<String> {
        let r = runCommand("/bin/ps", ["-Axco", "command"], timeout: 15)
        guard r.code == 0 else { return ["__process_lookup_failed__"] }
        let names = Set(r.out.split(separator: "\n")
            .map { prettyProcess(String($0)) }
            .filter { !$0.isEmpty })
        processCache.store(names)
        return names
    }

    /// Which apps are open changes by the second, but asking the system costs a
    /// process launch. One answer is reused for a few seconds, which is the
    /// difference between a menu that opens instantly and one that stutters.
    private static let processCache = ProcessSnapshot()

    private final class ProcessSnapshot {
        private let lock = NSLock()
        private var names: Set<String> = []
        private var takenAt: Double = 0

        func store(_ value: Set<String>) {
            lock.lock(); names = value; takenAt = nowTS(); lock.unlock()
        }

        func fresh(within seconds: Double) -> Set<String>? {
            lock.lock(); defer { lock.unlock() }
            guard takenAt > 0, nowTS() - takenAt < seconds else { return nil }
            return names
        }
    }

    /// The list of open apps, taken again only if the last look is older than
    /// `maxAge` seconds.
    static func runningProcessNames(maxAge: Double) -> Set<String> {
        if let cached = processCache.fresh(within: maxAge) { return cached }
        return runningProcessNames()
    }

    /// "Lark Helper (Renderer)" -> "Lark". Electron apps run a dozen helper
    /// processes; you do not want a menu telling you to quit six of them.
    static func prettyProcess(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if let open = name.firstIndex(of: "(") {
            name = String(name[name.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        }
        for suffix in [" Helper", " Renderer", " GPU", " Web Content", " Networking"]
        where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        // repeat once: "Lark Helper Helper"
        if name.hasSuffix(" Helper") { name = String(name.dropLast(7)) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Which app, if any, is holding this category open right now.
    static func blockingApp(_ categoryID: String, processes: Set<String>) -> String? {
        if processes.contains("__process_lookup_failed__") { return "Process status unavailable" }
        guard let hints = liveAppHints[categoryID] else { return nil }
        for name in processes {
            for hint in hints where name.lowercased().contains(hint.lowercased()) {
                return name
            }
        }
        return nil
    }

    static func ownerToken(_ path: String) -> String? {
        let home = Paths.home
        guard path.hasPrefix(home + "/") else { return nil }
        let rest = String(path.dropFirst(home.count + 1))
        let parts = rest.split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }
        if first.hasPrefix(".") {
            let tool = String(first.dropFirst())
            return tool.isEmpty ? nil : tool
        }
        guard first == "Library", parts.count >= 3 else { return nil }
        switch parts[1] {
        case "Caches", "Logs", "Application Support", "Containers",
             "HTTPStorages", "WebKit", "Saved Application State":
            if parts[2] == "Google", parts.count > 3 { return parts[3] }
            let aliases = ["company.thebrowser.Browser": "Arc", "com.microsoft.edgemac": "Microsoft Edge",
                           "org.mozilla.firefox": "Firefox", "com.brave.Browser": "Brave Browser"]
            return aliases[parts[2]] ?? parts[2]
        default:
            return nil
        }
    }

    /// Apps whose junk is safe to remove even while they run, because macOS or
    /// the app itself re-creates it on demand and nothing is held open.
    static let alwaysSafeOwners: Set<String> = [
        "com.apple.quicklook.thumbnailcache", "com.apple.helpd",
        "com.apple.spotlight", "com.apple.python", "cloudkit",
    ]

    /// Never let a two- or three-letter process name match half the disk.
    private static func processMatches(_ owner: String, _ process: String) -> Bool {
        let o = Catalog.prettyOwner(owner).lowercased()
        let p = process.lowercased()
        guard o.count >= 4, p.count >= 4 else { return o == p }
        return o.contains(p) || p.contains(o)
    }

    /// The app that owns this exact folder, if it happens to be running.
    static func blockingOwner(_ path: String, processes: Set<String>) -> String? {
        guard let owner = ownerToken(path) else { return nil }
        if alwaysSafeOwners.contains(owner.lowercased()) { return nil }
        for p in processes where processMatches(owner, p) { return p }
        return nil
    }

    static func plan(_ scan: ScanResult, includeIDs: Set<String>? = nil,
                     respectRunningApps: Bool = true,
                     processes: Set<String>? = nil) -> CleanPlan
    {
        var out: [CleanPlanItem] = []
        var skippedByApp: [String: Int64] = [:]
        let open: Set<String>
        if respectRunningApps {
            open = processes ?? runningProcessNames(maxAge: 5)
        } else {
            open = []
        }
        for cat in JunkScanner.dedupe(scan.categories) {
            if let ids = includeIDs {
                guard ids.contains(cat.id) else { continue }
            } else {
                guard cat.risk == .safe || cat.risk == .slower else { continue }
            }
            if cat.kind == .info { continue }
            if respectRunningApps, let app = blockingApp(cat.id, processes: open) {
                skippedByApp[app, default: 0] += cat.bytes
                continue
            }
            for item in cat.items {
                guard cat.risk == .review || !Catalog.requiresReview(item.path) else { continue }
                guard Safety.check(item.path, kind: cat.kind).isOK else { continue }
                guard Sizer.exists(item.path) else { continue }
                if respectRunningApps,
                   let app = blockingOwner(item.path, processes: open) {
                    skippedByApp[app, default: 0] += item.bytes
                    continue
                }
                out.append(CleanPlanItem(path: item.path, bytes: item.bytes,
                                         kind: cat.kind, category: cat.id,
                                         categoryTitle: cat.title, risk: cat.risk))
            }
        }
        out.sort { $0.bytes > $1.bytes }
        let blocked = skippedByApp.sorted { $0.value > $1.value }
            .map { (app: $0.key, bytes: $0.value) }
        return CleanPlan(items: out, blockedByApp: blocked)
    }

    static func apply(_ plan: [CleanPlanItem], cfg: Config,
                      runHomebrew: Bool = false,
                      progress: ((String) -> Void)? = nil) -> CleanOutcome
    {
        var outcome = CleanOutcome()
        guard !plan.isEmpty || runHomebrew else { return outcome }
        guard let operation = DiskOperation() else {
            outcome.failedCount = max(1, plan.count)
            return outcome
        }
        defer { operation.finish() }
        let name = stamp() + "-" + UUID().uuidString
        let batchDir = Paths.quarantineDir + "/" + name
        outcome.batchName = name
        do { try FileSafety.createDirectory(batchDir, privateMode: true) }
        catch { outcome.failedCount = max(1, plan.count); return outcome }
        var manifest = QuarantineManifest(created: name, keep_days: cfg.keepDays)
        guard writeManifest(manifest, to: batchDir) else {
            outcome.failedCount = max(1, plan.count); return outcome
        }
        var deleteNow: [QuarantineEntry] = []

        for item in plan {
            guard Catalog.enabled(item.path, cfg: cfg) else { continue }
            guard item.risk == .review || !Catalog.requiresReview(item.path) else {
                outcome.failedCount += 1
                manifest.failed.append(["path": item.path, "error": "requires explicit review"])
                continue
            }
            var validated = stat()
            guard lstat(item.path, &validated) == 0 else { continue }
            // last gate, immediately before touching the disk
            let pathVerdict = Safety.check(item.path, kind: item.kind)
            let verdict = pathVerdict.isOK ? Safety.checkContents(item.path, automatic: item.risk != .review) : pathVerdict
            guard verdict.isOK else {
                outcome.failedCount += 1
                manifest.failed.append(["path": item.path, "error": "blocked: " + verdict.reason])
                continue
            }
            guard Sizer.exists(item.path) else { continue }
            let processes = runningProcessNames()
            if let app = blockingApp(item.category, processes: processes)
                ?? blockingOwner(item.path, processes: processes) {
                outcome.skippedBecauseRunning.append(app)
                continue
            }
            let dst = batchDir + item.path   // absolute path appended, keeps structure
            // belt and braces: whatever the path looked like, the destination
            // has to land inside this batch folder and nowhere else
            guard (dst as NSString).standardizingPath.hasPrefix(batchDir + "/") else {
                outcome.failedCount += 1
                manifest.failed.append(["path": item.path, "error": "odd path, refused"])
                continue
            }
            do {
                try FileSafety.createDirectory((dst as NSString).deletingLastPathComponent, privateMode: true)
                let entry = QuarantineEntry(src: item.path, dst: dst, bytes: item.bytes,
                                            category: item.category, risk: item.risk.rawValue)
                // Persist the intended move first so a crash cannot orphan files.
                manifest.moved.append(entry)
                guard writeManifest(manifest, to: batchDir) else {
                    manifest.moved.removeLast()
                    outcome.failedCount += 1
                    break
                }
                try FileSafety.move(item.path, to: dst, expected: validated)
                outcome.movedBytes += item.bytes
                outcome.itemCount += 1
                outcome.parkedBytes += item.bytes
                if cfg.freeSafeItemsImmediately && item.risk == .safe { deleteNow.append(entry) }
                progress?("moved " + tildePath(item.path))
            } catch {
                if !Sizer.exists(dst) { manifest.moved.removeAll { $0.dst == dst } }
                manifest.failed.append(["path": item.path,
                                        "error": (error as NSError).localizedDescription])
                outcome.failedCount += 1
            }
        }

        for entry in deleteNow {
            do {
                // Recheck after moving: content may have changed since the scan.
                guard Safety.checkContents(entry.dst, automatic: true).isOK else {
                    throw FileSafety.error("Content changed or could not be verified; retained for inspection")
                }
                try FileSafety.removeTree(entry.dst)
                outcome.freedNowBytes += entry.bytes
                outcome.parkedBytes -= entry.bytes
                manifest.moved.removeAll { $0.dst == entry.dst }
            } catch {
                outcome.failedCount += 1
                manifest.failed.append(["path": entry.src, "error": "kept in safety net: " + error.localizedDescription])
            }
        }
        manifest.completed = outcome.failedCount == 0
        manifest.bytes = outcome.movedBytes
        manifest.freed_immediately = outcome.freedNowBytes
        if !writeManifest(manifest, to: batchDir) { outcome.failedCount += 1 }

        if runHomebrew, cfg.includeHomebrewCleanup, Homebrew.brewPath != nil {
            progress?("asking Homebrew to tidy up after itself")
            let r = Homebrew.cleanup()
            if r.ok {
                outcome.brewFreedBytes = Homebrew.parseSize(r.output)
                outcome.freedNowBytes += outcome.brewFreedBytes
            } else {
                outcome.failedCount += 1
            }
        }

        // if the batch ended up empty, do not leave an empty folder behind
        if manifest.moved.isEmpty && manifest.failed.isEmpty {
            try? FileSafety.removeTree(batchDir)
            outcome.batchName = ""
        }

        if !Config.recordFreed(outcome.freedNowBytes, cleaned: true) {
            outcome.failedCount += 1
            appLog("Could not save cleanup statistics")
        }

        for failure in manifest.failed { appLog("cleanup refused: " + (failure["path"] ?? "") + " — " + (failure["error"] ?? "unknown error")) }
        appLog("clean: moved \(human(outcome.movedBytes)) in \(outcome.itemCount) places, "
               + "freed now \(human(outcome.freedNowBytes)), parked \(human(outcome.parkedBytes))")
        ProjectScanner.invalidate()
        return outcome
    }

    @discardableResult
    static func writeManifest(_ m: QuarantineManifest, to dir: String) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        do {
            let data = try enc.encode(m)
            guard data.count <= 16 * 1024 * 1024 else { return false }
            try FileSafety.writeJournal(data, to: dir + "/manifest.json")
            return true
        } catch { return false }
    }

    /// Empty the Trash by hand: the only operation that is not reversible, and
    /// therefore the only one that always requires an explicit click. It refuses
    /// to look anywhere except at the top level of ~/.Trash, and it never
    /// follows a symlink out of it.
    static func emptyTrash() -> RemovalOutcome {
        guard let operation = DiskOperation() else { return RemovalOutcome(failed: 1) }
        defer { operation.finish() }
        let trash = Paths.expand("~/.Trash")
        guard Sizer.exists(trash) else { return RemovalOutcome() }
        guard Sizer.isDir(trash), !Safety.hasSymlinkComponent(trash),
              let directory = opendir(trash) else { return RemovalOutcome(failed: 1) }
        closedir(directory)
        var freed: Int64 = 0
        var failed = 0
        var removed = 0
        for name in Sizer.listDir(trash) {
            let path = trash + "/" + name
            guard (path as NSString).standardizingPath.hasPrefix(trash + "/") else { continue }
            let size = Sizer.measure(path, budget: 2.0)?.bytes ?? 0
            do {
                try FileSafety.removeTree(path)
                freed += size
                removed += 1
            } catch {
                failed += 1
            }
        }
        appLog("emptied Trash, freed \(human(freed))"
               + (failed > 0 ? ", \(failed) item(s) refused" : ""))
        if !Config.recordFreed(freed) { failed += 1; appLog("Could not save cleanup statistics") }
        return RemovalOutcome(bytes: freed, removed: removed, failed: failed)
    }

    /// Housekeeping that runs quietly: anything past its keep-days is erased.
    static func expireOldBatches(_ cfg: Config) -> Int64 {
        Quarantine.purge(olderThanDays: max(1, cfg.keepDays)).bytes
    }
}
