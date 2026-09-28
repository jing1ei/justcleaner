import Foundation

struct Config: Codable {
    var autoScanHours: Double = 6
    var keepDays: Double = 3
    var freeSafeItemsImmediately = true
    var includeBrowserCaches = true
    var includeHomebrewCleanup = true
    var scanProjects = true
    var scanPersonalFolders = false
    var showSizeInMenuBar = false
    var showSummaryAfterClean = true
    var notifyAboveGB: Double = 0
    var totalFreedBytes: Int64 = 0
    var lastCleanAt: Double = 0
    var installedAt: Double = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        autoScanHours = min(8760, max(0, try value(.autoScanHours, 6)))
        keepDays = min(3650, max(1, try value(.keepDays, 3)))
        freeSafeItemsImmediately = try value(.freeSafeItemsImmediately, true)
        includeBrowserCaches = try value(.includeBrowserCaches, true)
        includeHomebrewCleanup = try value(.includeHomebrewCleanup, true)
        scanProjects = try value(.scanProjects, true)
        scanPersonalFolders = try value(.scanPersonalFolders, false)
        showSizeInMenuBar = try value(.showSizeInMenuBar, false)
        showSummaryAfterClean = try value(.showSummaryAfterClean, true)
        notifyAboveGB = max(0, try value(.notifyAboveGB, 0))
        totalFreedBytes = max(0, try value(.totalFreedBytes, 0))
        lastCleanAt = min(nowTS(), max(0, try value(.lastCleanAt, 0)))
        installedAt = min(nowTS(), max(0, try value(.installedAt, 0)))
    }

    private static let mutex = NSLock()

    private static func read() throws -> Config? {
        var st = stat()
        if lstat(Paths.configFile, &st) != 0 {
            if errno == ENOENT { return nil }
            throw FileSafety.posixError()
        }
        guard !isLink(st), isRegularFile(st) else { throw FileSafety.error("Invalid settings file") }
        return try JSONDecoder().decode(Config.self, from: FileSafety.readFile(Paths.configFile, limit: 1024 * 1024))
    }

    static var loadIssue: String? {
        do { _ = try read(); return nil }
        catch { return "Settings could not be read. Cleanup is paused. Open Settings to repair or reset them; recovery files are preserved." }
    }

    static func load() -> Config {
        do { return try read() ?? Config() }
        catch {
            var fallback = Config()
            fallback.autoScanHours = 0
            fallback.freeSafeItemsImmediately = false
            fallback.includeHomebrewCleanup = false
            return fallback
        }
    }

    /// A separate lock serializes read-modify-write across GUI and CLI processes.
    /// Never acquire the disk-operation lock from inside this closure.
    private static func locked<T>(_ body: () throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        guard Paths.ensureStateDirs() else { throw FileSafety.error("Cannot open private settings storage") }
        let parent = try DirectoryHandle(Paths.stateDir)
        let fd = openat(parent.fd, "settings.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileSafety.posixError() }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
                throw FileSafety.error("Settings are busy; try again")
            }
            usleep(5_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 1024 * 1024 else { throw FileSafety.error("Settings exceeded size limit") }
        try FileSafety.writeJournal(data, to: Paths.configFile)
    }

    @discardableResult
    static func update(_ change: (inout Config) -> Void) -> Bool {
        do {
            try locked {
                var current = try read() ?? Config()
                if current.installedAt == 0 { current.installedAt = nowTS() }
                change(&current)
                try current.write()
            }
            return true
        } catch { return false }
    }

    @discardableResult
    static func recordFreed(_ bytes: Int64, cleaned: Bool = false) -> Bool {
        update {
            $0.totalFreedBytes = addBytes($0.totalFreedBytes, bytes)
            if cleaned { $0.lastCleanAt = nowTS() }
        }
    }

    /// Explicit replacement is used by fixture setup and the user's reset action.
    @discardableResult
    func save() -> Bool {
        do { try Self.locked { try write() }; return true }
        catch { return false }
    }

    static func reset() throws -> String? {
        try locked {
            var backup: String?
            if Sizer.exists(Paths.configFile) {
                let path = Paths.stateDir + "/config-backup-" + UUID().uuidString + ".json"
                try FileSafety.move(Paths.configFile, to: path)
                backup = path
            }
            var defaults = Config()
            defaults.installedAt = nowTS()
            do { try defaults.write() }
            catch {
                if let backup { try? FileSafety.move(backup, to: Paths.configFile) }
                throw error
            }
            return backup
        }
    }
}
