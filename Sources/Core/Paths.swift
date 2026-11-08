import Foundation

// Every path the app cares about, resolved once. Nothing is hard-coded to one
// particular Mac: the same build works on any machine, for any user name.

struct Paths {
    static let home = NSHomeDirectory()
    static let stateDir = home + "/.justcleaner"
    static let quarantineDir = stateDir + "/quarantine"
    static let reportsDir = stateDir + "/reports"
    static let configFile = stateDir + "/config.json"
    static let lastScanFile = stateDir + "/last-scan.json"
    static let logFile = stateDir + "/justcleaner.log"

    static func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        return p
    }

    @discardableResult
    static func ensureStateDirs() -> Bool {
        do {
            for d in [stateDir, quarantineDir] {
                try FileSafety.createDirectory(d, privateMode: true)
                let directory = try DirectoryHandle(d)
                guard fchmod(directory.fd, 0o700) == 0 else { return false }
            }
            if let reports = try? DirectoryHandle(reportsDir, create: true, privateMode: true) {
                _ = fchmod(reports.fd, 0o700)
            }
            return true
        } catch { return false }
    }

    static var machineName: String {
        Host.current().localizedName ?? "this Mac"
    }
}

/// One log file, appended from any thread, capped so it can never become the
/// junk it is meant to find.
private let logQueue = DispatchQueue(label: "com.justcleaner.log")
func appLog(_ message: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
    guard let data = line.data(using: .utf8) else { return }
    logQueue.async {
        guard Paths.ensureStateDirs() else { return }
        try? FileSafety.appendLog(data, to: Paths.logFile)
    }
}

/// Run a command with a timeout. Never throws, never hangs the UI.
/// Used only for optional extras (Homebrew, tool versions); the app works fine
/// when none of these exist.
func runCommand(_ launchPath: String, _ args: [String], timeout: Double = 30)
    -> (code: Int32, out: String)
{
    guard FileManager.default.isExecutableFile(atPath: launchPath) else {
        return (127, "")
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (127, "") }

    // Drain a nonblocking pipe on this worker. A descendant retaining stdout
    // cannot strand a readDataToEndOfFile thread after the command times out.
    pipe.fileHandleForWriting.closeFile()
    let fd = pipe.fileHandleForReading.fileDescriptor
    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
        if p.isRunning { p.terminate() }
        pipe.fileHandleForReading.closeFile()
        return (126, "Could not configure command output capture")
    }
    defer { pipe.fileHandleForReading.closeFile() }
    let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
    var data = Data()
    let limit = 4 * 1024 * 1024
    var truncated = false
    var eof = false
    var exceededDeadline = false
    var readFailed = false
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            let room = max(0, limit - data.count)
            data.append(contentsOf: buffer.prefix(min(count, room)))
            if count > room { truncated = true }
        } else if count == 0 { eof = true }
        else if errno != EAGAIN && errno != EINTR { eof = true; readFailed = true }
        if !p.isRunning && eof { break }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            exceededDeadline = true
            if p.isRunning {
                p.terminate()
                usleep(100_000)
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            break
        }
        if count <= 0 { usleep(10_000) }
    }
    let code: Int32 = exceededDeadline ? 124 : (readFailed ? 126 : (truncated ? 125 : (p.isRunning ? 124 : p.terminationStatus)))
    return (code, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func findExecutable(_ name: String) -> String? {
    var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                "/usr/sbin", "/sbin",
                Paths.home + "/.cargo/bin",
                Paths.home + "/.local/bin",
                Paths.home + "/.bun/bin",
                Paths.home + "/go/bin"]
    if let envPath = ProcessInfo.processInfo.environment["PATH"] {
        dirs = envPath.split(separator: ":").map(String.init) + dirs
    }
    var seen = Set<String>()
    for d in dirs where !d.isEmpty {
        if seen.contains(d) { continue }
        seen.insert(d)
        let candidate = d + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// git is safe to run only when Apple's command line tools really are present:
/// /usr/bin/git is otherwise a stub that pops up an installer dialog, which is
/// exactly what a silent background app must never do.
func safeGitPath() -> String? {
    if let g = findExecutable("git"), !g.hasPrefix("/usr/bin") { return g }
    let fm = FileManager.default
    if fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
        || fm.fileExists(atPath: "/Applications/Xcode.app") {
        return "/usr/bin/git"
    }
    return nil
}

/// True when a command exists and is not one of Apple's "install me first" stubs.
func realExecutable(_ name: String) -> String? {
    guard let p = findExecutable(name) else { return nil }
    if p.hasPrefix("/usr/bin/") {
        let fm = FileManager.default
        let cltPresent = fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/" + name)
        let xcodePresent = fm.fileExists(atPath: "/Applications/Xcode.app")
        // python3, git, swift, clang and friends live in /usr/bin as stubs
        let stubNames: Set<String> = ["git", "python3", "swift", "swiftc", "clang",
                                      "make", "java", "javac", "gcc", "ruby"]
        if stubNames.contains(name) && !cltPresent && !xcodePresent { return nil }
    }
    return p
}

/// Serialize disk mutations across threads and processes.
final class DiskOperation {
    private static let mutex = NSLock()
    private var descriptor: Int32 = -1
    init?(requiresValidConfig: Bool = true) {
        guard Self.mutex.try() else { return nil }
        guard !Safety.hasSymlinkComponent(Paths.stateDir),
              !Safety.hasSymlinkComponent(Paths.quarantineDir) else {
            Self.mutex.unlock(); return nil
        }
        guard Paths.ensureStateDirs(), !requiresValidConfig || Config.loadIssue == nil else {
            Self.mutex.unlock(); return nil
        }
        descriptor = open(Paths.stateDir + "/operation.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            descriptor = -1
            Self.mutex.unlock(); return nil
        }
    }
    func finish() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
        Self.mutex.unlock()
    }
    deinit { finish() }
}
