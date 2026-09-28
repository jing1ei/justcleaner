import AppKit

if CommandLine.arguments.contains("--settings-worker") {
    for _ in 0..<15 {
        guard Config.recordFreed(1) else { exit(1) }
    }
    exit(0)
}

let fm = FileManager.default
try fm.createDirectory(atPath: Paths.home, withIntermediateDirectories: true)
Paths.ensureStateDirs()
var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) }
    else { failures += 1; print("FAIL: " + label) }
}
func put(_ path: String, bytes: Int = 4096) throws {
    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(repeating: 42, count: bytes).write(to: URL(fileURLWithPath: path))
}
let protected = Paths.home + "/Music/project"
try put(protected + "/Cache/song.wav")
let alias = Paths.home + "/.tool"
try fm.createSymbolicLink(atPath: alias, withDestinationPath: protected)
expect(!Safety.check(alias + "/Cache", kind: .dotJunk).isOK, "symlink ancestor cannot expose protected music")
let cfg = try JSONDecoder().decode(Config.self, from: Data("{\"keepDays\":-1,\"autoScanHours\":-5}".utf8))
expect(cfg.keepDays >= 1 && cfg.autoScanHours >= 0, "invalid retention and interval are normalized")
let timed = runCommand("/bin/sh", ["-c", "trap 'exit 0' TERM; while :; do sleep 0.1; done"], timeout: 0.1)
expect(timed.code == 124, "timeout cannot report success after SIGTERM")

for t in Safety.selfTestCases() {
    expect(Safety.check(t.path, kind: t.kind).isOK == t.mustBeAllowed, "safety: " + tildePath(t.path))
}
var config = Config()
config.includeHomebrewCleanup = false
config.freeSafeItemsImmediately = false
config.save()
func item(_ path: String, risk: Risk = .safe) -> CleanPlanItem {
    CleanPlanItem(path: path, bytes: Sizer.measure(path)?.bytes ?? 0,
                  kind: .cache, category: "fixture", categoryTitle: "Fixture", risk: risk)
}
let cache = Paths.home + "/Library/Caches/FixtureOne"
try put(cache + "/data")
let first = Cleaner.apply([item(cache)], cfg: config)
expect(first.itemCount == 1 && first.parkedBytes > 0 && !Sizer.exists(cache), "cleanup parks disposable files")
let batch = Quarantine.batches().first!
expect(batch.manifest?.moved.count == 1, "recovery record survives reload")
try put(cache + "/new-data")
let conflict = Quarantine.restore(batch)
expect(conflict.failed == 1 && Sizer.exists(cache + "/new-data"), "undo preserves new content at original path")
try fm.removeItem(atPath: cache)
let restored = Quarantine.restore(Quarantine.batches().first!)
expect(restored.restored == 1 && Sizer.exists(cache + "/data"), "undo retries retained entries successfully")
let guarded = Paths.home + "/Library/Caches/FixtureProtected"
try put(guarded + "/recording.wav")
expect(!Safety.checkContents(guarded).isOK, "protected descendant blocks parent cleanup")
let refused = Cleaner.apply([item(guarded)], cfg: config)
expect(refused.failedCount > 0 && Sizer.exists(guarded + "/recording.wav"), "apply preserves music inside a cache")
config.freeSafeItemsImmediately = true
let immediate = Paths.home + "/Library/Caches/FixtureImmediate"
try put(immediate + "/data")
let freed = Cleaner.apply([item(immediate)], cfg: config)
expect(freed.freedNowBytes > 0 && freed.parkedBytes == 0, "successful deletion accounts for freed bytes")
let locked = Paths.home + "/Library/Caches/FixtureLocked"
try put(locked + "/data")
let failedDelete = Cleaner.apply([item(locked)], cfg: config) { _ in
    for b in Quarantine.batches() {
        for e in b.manifest?.moved ?? [] where e.src == locked {
            _ = chflags(e.dst + "/data", UInt32(UF_IMMUTABLE))
        }
    }
}
expect(failedDelete.freedNowBytes == 0 && failedDelete.parkedBytes > 0 && failedDelete.failedCount > 0,
       "failed deletion stays recoverable and is not counted as freed")
if let lockedBatch = Quarantine.batches().first(where: { $0.manifest?.moved.contains(where: { $0.src == locked }) == true }) {
    for e in lockedBatch.manifest!.moved { _ = chflags(e.dst + "/data", 0) }
    expect(Quarantine.restore(lockedBatch).restored == 1, "failed immediate deletion can be undone")
} else { expect(false, "failed deletion retains its manifest") }
let guardLock = DiskOperation()!
let concurrent = Cleaner.apply([item(cache)], cfg: config)
expect(concurrent.failedCount > 0 && Sizer.exists(cache), "concurrent cleanup is refused")
guardLock.finish()
config.includeBrowserCaches = false
expect(!Catalog.enabled(Paths.home + "/Library/Caches/Google", cfg: config), "general Google cache obeys browser setting")
expect(Cleaner.blockingOwner(Paths.home + "/Library/Caches/Google/Chrome", processes: ["Google Chrome"]) != nil,
       "running Chrome protects nested Google cache")
expect(Cleaner.blockingOwner(Paths.home + "/Library/Caches/company.thebrowser.Browser", processes: ["Arc"]) != nil,
       "running Arc protects reverse-DNS cache")
expect(CLI.run(["clean", "--only"]) == 2, "missing category cannot fall through to full clean")
expect(CLI.run(["clean", "--dryrun"]) == 2, "misspelled preview option cannot perform cleanup")
expect(CLI.run(["purge", "--older-than", "nan"]) == 2, "invalid purge age fails before mutation")
expect(CLI.run(["unknown"]) == 2, "unknown command returns failure")
let badBatch = Batch(name: "bad", path: Paths.home, bytes: 4096,
    manifest: QuarantineManifest(created: "bad", keep_days: 3), createdAt: nowTS())
expect(Quarantine.restore(badBatch).failed > 0 && Sizer.exists(cache), "undo rejects a batch outside quarantine")
expect(!Cleaner.writeManifest(QuarantineManifest(created: "bad", keep_days: 3), to: Paths.home + "/missing/path"),
       "manifest write failure is observable")
let wide = Paths.home + "/wide"
for n in 0..<600 { try put(wide + "/f\(n)", bytes: 1) }
expect(Sizer.measure(wide, budget: 0)?.partial == true, "size budget applies to a wide single folder")
var reportScan = ScanResult()
reportScan.machine = "Fixture <Mac>"
reportScan.finishedAt = nowTS()
reportScan.disk = DiskSnapshot(total: 1_000_000_000, free: 500_000_000, used: 500_000_000)
let parentFinding = Finding(path: cache, bytes: 4096, files: 1, mtime: nowTS(), note: "test")
let childFinding = Finding(path: cache + "/data", bytes: 4096, files: 1, mtime: nowTS(), note: "test")
let duplicateCategories = [
    CategoryResult(id: "a", group: "Test", title: "A", what: "A", risk: .safe, kind: .cache, items: [parentFinding]),
    CategoryResult(id: "b", group: "Test", title: "B", what: "B", risk: .safe, kind: .cache, items: [childFinding, parentFinding])]
expect(JunkScanner.dedupe(duplicateCategories).reduce(0) { $0 + $1.items.count } == 1, "overlapping cache folders are counted once")
let sampleProject = Paths.home + "/code/project/node_modules"
try put(sampleProject + "/dep")
var previous = ScanResult()
previous.categories = [CategoryResult(id: "project-builds", group: "Review", title: "Project", what: "test", risk: .review,
    kind: .artifact, items: [Finding(path: sampleProject, bytes: 4096, files: 1, mtime: nowTS(), note: "test")])]
JunkScanner.save(previous)
config.scanProjects = false
let quick = JunkScanner.scan(deep: false, cfg: config)
expect(quick.category("project-builds") == nil && quick.repos.isEmpty, "turning project scans off removes carried-over results")
expect(Homebrew.parseSize("approximately 1e100 GB") == 0, "oversized external size output cannot crash")
let reportPath = try Report.write(reportScan, cfg: config)
expect((try? String(contentsOfFile: reportPath, encoding: .utf8))?.contains("Fixture &lt;Mac&gt;") == true, "report escapes machine names and saves")
if let output = ProcessInfo.processInfo.environment["MACTIDY_TEST_REPORT"] {
    try Report.html(reportScan, cfg: config).write(toFile: output, atomically: true, encoding: .utf8)
}
try fm.removeItem(atPath: Paths.reportsDir)
try put(Paths.reportsDir)
do { _ = try Report.write(reportScan, cfg: config); expect(false, "report write failure throws") }
catch { expect(true, "report write failure throws") }
expect(MenuPresentation.cleanTitle(nil, busy: false) == "Scan before cleaning", "first run does not claim the Mac is clean")
expect(MenuPresentation.cleanTitle(nil, busy: true) == "Working…", "busy state suppresses cleanup")
var occupied = ScanResult()
occupied.categories = duplicateCategories
occupied.blockedBytes = occupied.cleanableBytes
expect(MenuPresentation.cleanTitle(occupied, busy: false) == "Caches are in use", "fully blocked cleanup has a useful reason")
expect(MenuPresentation.compact(String(repeating: "界", count: 150), limit: 64).count == 64, "long Unicode paths fit menu rows")
expect(!badBatch.isRestorable, "empty recovery records do not offer Undo")
let exclusive = DiskOperation()!
expect(Quarantine.purgeAll().failed > 0, "purge reports another operation instead of success")
expect(Cleaner.emptyTrash().failed > 0, "Trash reports another operation instead of success")
exclusive.finish()
let trashFile = Paths.home + "/.Trash/fixture"
try put(trashFile)
_ = chflags(trashFile, UInt32(UF_IMMUTABLE))
expect(Cleaner.emptyTrash().failed > 0 && Sizer.exists(trashFile), "failed Trash removal stays visible")
_ = chflags(trashFile, 0)
expect(Cleaner.emptyTrash().removed == 1, "Trash can retry after a failure")
let hardRoot = Paths.home + "/hardlinks"
try put(hardRoot + "/one")
try fm.linkItem(atPath: hardRoot + "/one", toPath: hardRoot + "/two")
expect(Sizer.measure(hardRoot)?.bytes == Sizer.measure(hardRoot + "/one")?.bytes, "hard-linked files are counted once within a tree")
let live = Paths.home + "/Library/Caches/FreshManifest"
try put(live + "/data")
var parkConfig = config
parkConfig.freeSafeItemsImmediately = false
let parked = Cleaner.apply([item(live)], cfg: parkConfig)
if let saved = Quarantine.batches().first(where: { $0.name == parked.batchName }) {
    var fresh = saved.manifest!
    let second = Paths.home + "/Library/Caches/OtherFresh"
    try put(saved.path + second + "/data")
    fresh.moved.append(QuarantineEntry(src: second, dst: saved.path + second, bytes: 4096, category: "fixture"))
    Cleaner.writeManifest(fresh, to: saved.path)
    expect(Quarantine.restore(saved).restored == 2 && Sizer.exists(second + "/data"), "Undo rereads manifest instead of deleting unseen recovery files")
} else { expect(false, "fresh recovery batch exists") }
var detailed = reportScan
detailed.categories = [CategoryResult(id: "test", group: "Test", title: "All folders", what: "Example", risk: .safe, kind: .cache,
    items: (1...20).map { Finding(path: Paths.home + "/Library/Caches/Folder\($0)", bytes: 4096, files: 1, mtime: nowTS(), note: "Example", partial: $0 == 20) })]
let detailedHTML = Report.html(detailed, cfg: config)
expect(detailedHTML.contains("Folder20") && detailedHTML.contains("Show all 20"), "full report exposes folders beyond the old display limit")
expect(detailedHTML.contains("at least"), "incomplete measurements are labelled in report")
if let output = ProcessInfo.processInfo.environment["MACTIDY_TEST_REPORT"] {
    try detailedHTML.write(toFile: output, atomically: true, encoding: .utf8)
}
// Engineering regression probes, run only in the test home.
expect(!Safety.check(Paths.home + "/.CACHE", kind: .cache).isOK, "case variant of critical cache root is protected")
expect(!Safety.check(Paths.home + "/.cache/a\0suffix", kind: .cache).isOK, "NUL path is refused before POSIX truncation")
let badSettings = Data("{broken-json".utf8)
try badSettings.write(to: URL(fileURLWithPath: Paths.configFile))
let fallback = Config.load()
expect(!fallback.freeSafeItemsImmediately && !fallback.includeHomebrewCleanup && fallback.autoScanHours == 0,
       "corrupt settings fail closed")
expect(fm.contents(atPath: Paths.configFile) == badSettings, "corrupt settings are preserved for recovery")
config.save()
let parentCache = Paths.home + "/.cache"
let modelCache = parentCache + "/huggingface"
let sensitive = CategoryResult(id: "ai-models", group: "Review", title: "Models", what: "test", risk: .review, kind: .cache,
    items: [Finding(path: modelCache, bytes: 4096, files: 1, mtime: nowTS(), note: "test")])
let parentCat = CategoryResult(id: "ai-tools", group: "Automatic", title: "Cache", what: "test", risk: .safe, kind: .dotJunk,
    items: [Finding(path: parentCache, bytes: 8192, files: 2, mtime: nowTS(), note: "test")])
let separated = JunkScanner.dedupe([parentCat, sensitive])
expect(separated.first?.items.isEmpty == true && separated.last?.items.count == 1,
       "automatic ancestor cannot absorb a review-only descendant")
let orphanSource = Paths.home + "/Library/Caches/OrphanCheck"
try put(orphanSource + "/data")
var retain = config
retain.freeSafeItemsImmediately = false
let orphanOutcome = Cleaner.apply([item(orphanSource)], cfg: retain)
if let orphanBatch = Quarantine.batches().first(where: { $0.name == orphanOutcome.batchName }) {
    let extra = orphanBatch.path + "/unlisted-important-file"
    try put(extra)
    let restoreResult = Quarantine.restore(orphanBatch)
    expect(restoreResult.restored == 1 && Sizer.exists(extra), "Undo preserves unlisted batch content")
} else { expect(false, "orphan probe created batch") }


let renameFrom = Paths.home + "/rename-from"
let renameTo = Paths.home + "/rename-to"
try put(renameFrom)
try put(renameTo)
do { try FileSafety.move(renameFrom, to: renameTo); expect(false, "exclusive rename refuses existing destination") }
catch { expect(Sizer.exists(renameFrom) && Sizer.exists(renameTo), "exclusive rename refuses existing destination") }
try fm.removeItem(atPath: renameTo)
var identity = stat()
_ = lstat(renameFrom, &identity)
try fm.moveItem(atPath: renameFrom, toPath: renameFrom + "-original")
try put(renameFrom)
do { try FileSafety.move(renameFrom, to: renameTo, expected: identity); expect(false, "changed inode refused") }
catch { expect(Sizer.exists(renameFrom), "changed inode refused") }
try FileSafety.move(renameFrom, to: renameTo)
expect(!Sizer.exists(renameFrom) && Sizer.exists(renameTo), "exclusive rename succeeds without copy fallback")
let aliasParent = Paths.home + "/alias-parent"
try fm.createSymbolicLink(atPath: aliasParent, withDestinationPath: Paths.home)
do { try FileSafety.move(aliasParent + "/rename-to", to: Paths.home + "/renamed"); expect(false, "move refuses symlink parent") }
catch { expect(Sizer.exists(renameTo), "move refuses symlink parent") }
let interruptedDir = Paths.quarantineDir + "/interrupted"
try put(interruptedDir + "/unlisted")
var interrupted = QuarantineManifest(created: "interrupted", keep_days: 1)
interrupted.created_at = nowTS() - 10 * 86400
Cleaner.writeManifest(interrupted, to: interruptedDir)
_ = Quarantine.purge(olderThanDays: 1)
expect(Sizer.exists(interruptedDir + "/unlisted"), "automatic expiry preserves interrupted batches")
let privateAttrs = try fm.attributesOfItem(atPath: Paths.quarantineDir)
expect((privateAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "safety net is private to the current user")
let noisy = runCommand("/bin/sh", ["-c", "head -c 5000000 /dev/zero"], timeout: 5)
expect(noisy.code == 125 && noisy.out.utf8.count <= 4 * 1024 * 1024, "command output is bounded and truncation fails visibly")
let pipeStart = ProcessInfo.processInfo.systemUptime
let heldPipe = runCommand("/bin/sh", ["-c", "sleep 1 & exit 0"], timeout: 0.1)
expect(heldPipe.code == 124 && ProcessInfo.processInfo.systemUptime - pipeStart < 0.8, "inherited pipe cannot strand command reader")
let beforeConfig = fm.contents(atPath: Paths.configFile)!
try Data("{\"freeSafeItemsImmediately\":\"no\"}".utf8).write(to: URL(fileURLWithPath: Paths.configFile))
expect(Config.loadIssue != nil && DiskOperation() == nil, "wrong-type deletion preference pauses disk mutation")
try beforeConfig.write(to: URL(fileURLWithPath: Paths.configFile))
let nestedReview = Paths.home + "/.nested/cache"
try put(nestedReview + "/models/weights.bin")
expect(!Safety.checkContents(nestedReview, automatic: true).isOK, "automatic parent cannot hide review data within its tree")
expect(addBytes(Int64.max, 1) == Int64.max, "freed-space statistics cannot overflow")
expect(Catalog.requiresReview(Paths.home + "/.tool/cache/models"), "quick-scan shape rules preserve model directories")
expect(!Safety.junkFolderNames.contains("blob_storage"), "persistent Chromium blobs are not classified as throwaway by name")


let preferencesBefore = fm.contents(atPath: Paths.configFile)!
try Data("{broken".utf8).write(to: URL(fileURLWithPath: Paths.configFile))
expect(CLI.run(["clean", "--yes"]) == 1, "CLI refuses destructive action when settings are corrupt")
try preferencesBefore.write(to: URL(fileURLWithPath: Paths.configFile))
var queued = ScanResult()
queued.finishedAt = nowTS()
queued.categories = [CategoryResult(id: "fixture", group: "Test", title: "Test", what: "Test", risk: .safe, kind: .cache,
  items: [Finding(path: cache, bytes: 4096, files: 1, mtime: nowTS(), note: "test")])]
JunkScanner.save(queued)
expect(CLI.run(["clean"]) == 2 && Sizer.exists(cache), "noninteractive clean requires explicit yes")
let stale = Paths.home + "/Library/Caches/ChangedAfterMove"
try put(stale + "/data")
var immediateConfig = config
immediateConfig.freeSafeItemsImmediately = true
let changed = Cleaner.apply([item(stale)], cfg: immediateConfig) { _ in
    for batch in Quarantine.batches() {
        for entry in batch.manifest?.moved ?? [] where entry.src == stale {
            try? put(entry.dst + "/recording.wav")
        }
    }
}
expect(changed.failedCount > 0 && changed.freedNowBytes == 0 && changed.parkedBytes > 0,
       "protected content appearing after move prevents immediate deletion")
if let changedBatch = Quarantine.batches().first(where: { $0.name == changed.batchName }) {
    expect(changedBatch.manifest?.completed == false, "failed post-move validation disables automatic expiry")
}

let unknownDir = Paths.quarantineDir + "/completed-with-extra"
try put(unknownDir + "/extra")
var unknown = QuarantineManifest(created: "completed-with-extra", keep_days: 1)
unknown.completed = true
unknown.created_at = nowTS() - 10 * 86400
Cleaner.writeManifest(unknown, to: unknownDir)
_ = Quarantine.purge(olderThanDays: 1)
expect(Sizer.exists(unknownDir + "/extra"), "automatic expiry preserves unlisted recovery files even in completed batches")
expect(Config.update { $0.totalFreedBytes = 0; $0.keepDays = 7 }, "transactional settings setup succeeds")
var workers: [Process] = []
for _ in 0..<3 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--settings-worker"]
    try process.run()
    workers.append(process)
}
expect(Config.update { $0.showSizeInMenuBar = true }, "preference change succeeds during concurrent statistics updates")
for worker in workers { worker.waitUntilExit() }
let merged = Config.load()
expect(workers.allSatisfy { $0.terminationStatus == 0 } && merged.totalFreedBytes == 45,
       "independent processes preserve every statistics update")
expect(merged.keepDays == 7 && merged.showSizeInMenuBar, "statistics writes preserve unrelated preferences")
let broken = Data("{broken-settings".utf8)
try broken.write(to: URL(fileURLWithPath: Paths.configFile))
let savedBackup = try Config.reset()
expect(savedBackup.flatMap { fm.contents(atPath: $0) } == broken && Config.loadIssue == nil,
       "reset preserves corrupt settings and restores usable defaults")
expect(Sizer.exists(Paths.quarantineDir), "settings reset preserves recovery storage")
let outsideRemoval = Paths.home + "/keep-outside-removal"
try put(outsideRemoval)
let removalRoot = Paths.home + "/remove-tree"
try fm.createDirectory(atPath: removalRoot, withIntermediateDirectories: true)
try fm.createSymbolicLink(atPath: removalRoot + "/link", withDestinationPath: outsideRemoval)
try put(removalRoot + "/nested/file")
try FileSafety.removeTree(removalRoot)
expect(Sizer.exists(outsideRemoval) && !Sizer.exists(removalRoot), "descriptor removal deletes links without following their targets")
let purgeLock = DiskOperation()!
expect(Quarantine.purge(olderThanDays: 1).failed == 1, "age-based purge reports lock contention")
purgeLock.finish()
var unavailable = ScanResult()
unavailable.blockedBytes = 1024
unavailable.blockedApps = ["Process status unavailable"]
expect(unavailable.blockedSentence == "Could not check running apps. Scan again before cleaning.",
       "unavailable process status offers a valid recovery action")
let expiryDir = Paths.quarantineDir + "/expired-locked"
let expirySrc = Paths.home + "/Library/Caches/ExpiryTest"
try put(expiryDir + expirySrc + "/data")
var expiryManifest = QuarantineManifest(created: "expired-locked", keep_days: 1,
    moved: [QuarantineEntry(src: expirySrc, dst: expiryDir + expirySrc, bytes: 4096, category: "fixture")])
expiryManifest.completed = true
expiryManifest.created_at = nowTS() - 10 * 86400
Cleaner.writeManifest(expiryManifest, to: expiryDir)
_ = chflags(expiryDir + expirySrc + "/data", UInt32(UF_IMMUTABLE))
let expiryFailed = Quarantine.purge(olderThanDays: 1)
expect(expiryFailed.failed == 1 && Sizer.exists(expiryDir + expirySrc + "/data"), "age-based purge reports failed removal")
_ = chflags(expiryDir + expirySrc + "/data", 0)
let expiryRetry = Quarantine.purge(olderThanDays: 1)
expect(expiryRetry.failed == 0 && expiryRetry.removed == 1, "age-based purge retries successfully")
// Shared filesystem boundaries must reject malformed paths before any mutation.
let boundary = Paths.home + "/boundary"
try put(boundary + "/keep")
do {
    try FileSafety.writeJournal(Data("bad".utf8), to: boundary + "/record\0suffix")
    expect(false, "journal rejects NUL destination")
} catch { expect(!Sizer.exists(boundary + "/record"), "journal rejects NUL destination") }
let hostileDir = Paths.home + "/hostile"
try put(hostileDir + "/child/data")
do {
    try FileSafety.removeTree(hostileDir + "/child/..")
    expect(false, "removal rejects parent leaf")
} catch { expect(Sizer.exists(hostileDir + "/child/data"), "removal rejects parent leaf") }

let readTarget = Paths.home + "/bounded-read"
try put(readTarget, bytes: 2048)
do { _ = try FileSafety.readFile(readTarget, limit: 1024); expect(false, "oversized file rejected") }
catch { expect(true, "oversized file rejected") }
let readLink = Paths.home + "/bounded-link"
try fm.createSymbolicLink(atPath: readLink, withDestinationPath: readTarget)
do { _ = try FileSafety.readFile(readLink, limit: 4096); expect(false, "serialized state refuses symbolic links") }
catch { expect(true, "serialized state refuses symbolic links") }
let fifo = Paths.home + "/state-fifo"
_ = mkfifo(fifo, 0o600)
let fifoStart = ProcessInfo.processInfo.systemUptime
do { _ = try FileSafety.readFile(fifo, limit: 4096); expect(false, "FIFO rejected without blocking") }
catch { expect(ProcessInfo.processInfo.systemUptime - fifoStart < 1, "FIFO rejected without blocking") }
let logTarget = Paths.home + "/log-target"
try put(logTarget)
let targetBefore = fm.contents(atPath: logTarget)
let logLink = Paths.home + "/log-link"
try fm.createSymbolicLink(atPath: logLink, withDestinationPath: logTarget)
do { try FileSafety.appendLog(Data("unsafe".utf8), to: logLink); expect(false, "log refuses symlink") }
catch { expect(fm.contents(atPath: logTarget) == targetBefore, "log refuses symlink") }
let logHardLink = Paths.home + "/log-hardlink"
try fm.linkItem(atPath: logTarget, toPath: logHardLink)
do { try FileSafety.appendLog(Data("unsafe".utf8), to: logHardLink); expect(false, "log refuses hard-linked destination") }
catch { expect(fm.contents(atPath: logTarget) == targetBefore, "log refuses hard-linked destination") }
let boundedLog = Paths.home + "/bounded-log"
try FileSafety.appendLog(Data(repeating: 65, count: 3000), to: boundedLog, limit: 1024)
expect((try? FileSafety.readFile(boundedLog, limit: 1024).count) == 1024, "log stays within its byte limit")
let corruptScan = ScanResult(categories: [CategoryResult(id: "bad", group: "Bad", title: "Bad", what: "Bad", risk: .safe, kind: .cache,
    items: [Finding(path: cache, bytes: Int64.max, files: 1, mtime: nowTS(), note: "bad"), Finding(path: cache, bytes: 1, files: 1, mtime: nowTS(), note: "bad")])])
JunkScanner.save(corruptScan)
expect(JunkScanner.loadLast() == nil, "overflowing saved scan is rejected before rendering")
let invalidManifestPath = Paths.quarantineDir + "/invalid-manifest"
try fm.createDirectory(atPath: invalidManifestPath, withIntermediateDirectories: true)
var invalidManifest = QuarantineManifest(created: "bad", keep_days: 3)
invalidManifest.moved = [QuarantineEntry(src: cache, dst: invalidManifestPath + cache, bytes: -1, category: "bad")]
Cleaner.writeManifest(invalidManifest, to: invalidManifestPath)
expect(Quarantine.readManifest(invalidManifestPath) == nil, "negative recovery sizes are rejected")
JunkScanner.save(detailed)
let originalSettings = fm.contents(atPath: Paths.configFile)!
try fm.removeItem(atPath: Paths.configFile)
_ = mkfifo(Paths.configFile, 0o600)
let settingsStart = ProcessInfo.processInfo.systemUptime
expect(Config.loadIssue != nil && ProcessInfo.processInfo.systemUptime - settingsStart < 1,
       "FIFO configuration is rejected without hanging the menu")
try fm.removeItem(atPath: Paths.configFile)
try originalSettings.write(to: URL(fileURLWithPath: Paths.configFile))
let agentParent = Paths.home + "/Library/LaunchAgents"
let agentTarget = Paths.home + "/agent-target"
try fm.createDirectory(atPath: agentTarget, withIntermediateDirectories: true)
if Sizer.exists(agentParent) { try fm.removeItem(atPath: agentParent) }
try fm.createSymbolicLink(atPath: agentParent, withDestinationPath: agentTarget)
expect(!LoginItem.enable() && Sizer.listDir(agentTarget).isEmpty,
       "login setup refuses redirected LaunchAgents directory")
try fm.removeItem(atPath: agentParent)
expect(LoginItem.enable(), "login preference writes a valid plist")
let agentData = try FileSafety.readFile(LoginItem.plistPath, limit: 65536)
let agentPlist = try PropertyListSerialization.propertyList(from: agentData, format: nil) as! [String: Any]
expect((agentPlist["ProgramArguments"] as? [String]) == [LoginItem.executablePath], "login plist targets the running executable")
expect(LoginItem.disable(), "login preference can be disabled")
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let controller = MenuController(startAutomatically: false)
controller.scan = nil
controller.rebuild()
expect(controller.cleanItem?.isEnabled == false && controller.cleanItem?.title == "Scan before cleaning", "native first-run cleanup is disabled")
controller.scan = occupied
controller.rebuild()
expect(controller.cleanItem?.isEnabled == false, "native blocked cleanup is disabled")
controller.scan = detailed
controller.rebuild()
controller.batches = (0..<12).map {
    Batch(name: "batch\($0)", path: Paths.quarantineDir + "/batch\($0)", bytes: 4096,
          manifest: QuarantineManifest(created: "batch\($0)", keep_days: 3), createdAt: nowTS())
}
let recoveryMenu = controller.safetyNetSubmenu(49152)
expect(recoveryMenu.items.first(where: { $0.title == "Older cleanups (4)" })?.submenu?.items.count == 4,
       "older recovery batches remain reachable")
let menuCount = controller.menu.numberOfItems
controller.menuIsOpen = true
let headline = controller.headlineItem
controller.work("Testing") {}
expect(controller.headlineItem === headline && controller.menu.numberOfItems == menuCount, "work starting preserves an open menu's structure")
func disabled(_ menu: NSMenu) -> Bool {
    menu.items.allSatisfy { ($0.action == nil || !$0.isEnabled) && ($0.submenu.map(disabled) ?? true) }
}
expect(disabled(controller.menu), "busy state disables every native submenu action")
controller.finishWork()
expect(controller.cleanItem?.isEnabled == true, "finishing work restores native cleanup action")
expect(controller.menu.items.first(where: { $0.action == #selector(MenuController.rescan) })?.isEnabled == true,
       "finishing work restores scan action without closing the menu")
controller.menuIsOpen = false
controller.rebuild()
controller.work("Second job") {}
let currentOperation = controller.operationID
let deadline = Date().addingTimeInterval(1)
while controller.operationID != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
expect(currentOperation != nil && controller.operationID == nil, "old completion cannot strand or overwrite a newer job")
var emptyDeep = ScanResult()
emptyDeep.mode = "deep"
controller.scan = emptyDeep
controller.rebuild()
expect(controller.menu.items.contains { $0.action == #selector(MenuController.deepScan) && $0.isEnabled },
       "empty deep scan still offers another deep scan")
let more = controller.menu.items.first { $0.title == "More" }?.submenu
expect(more?.items.contains { $0.action == #selector(MenuController.packForAnotherMac) } == true,
       "export remains reachable in compact menu")
expect(controller.menu.items.filter { $0.action == #selector(MenuController.deepScan) }.count == 1,
       "main menu has one unambiguous deep scan action")
controller.scan = detailed
controller.rebuild()
let previousAppearance = application.appearance
func menusMatch(_ menu: NSMenu, _ mode: NSAppearance.Name) -> Bool {
    menu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == mode
        && menu.items.allSatisfy { $0.submenu.map { menusMatch($0, mode) } ?? true }
}
for mode in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
    application.appearance = NSAppearance(named: mode)
    let limit = Date().addingTimeInterval(1)
    while !menusMatch(controller.menu, mode) && Date() < limit {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    expect(menusMatch(controller.menu, mode), "all menus follow application appearance: " + mode.rawValue)
}
controller.menuIsOpen = true
let appearanceHeadline = controller.headlineItem
application.appearance = NSAppearance(named: .darkAqua)
let appearanceDeadline = Date().addingTimeInterval(1)
while !menusMatch(controller.menu, .darkAqua) && Date() < appearanceDeadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
expect(menusMatch(controller.menu, .darkAqua) && controller.headlineItem === appearanceHeadline,
       "appearance changes preserve the open menu structure")
controller.menuIsOpen = false
application.appearance = previousAppearance
controller.synchronizeAppearance()

print("\(failures) regression failure(s)")
exit(failures == 0 ? 0 : 1)
