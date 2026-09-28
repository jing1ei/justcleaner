import Foundation

/// Open every directory component without following links. Holding these file
/// descriptors pins the parents used by a move even if their names change.
final class DirectoryHandle {
    let fd: Int32
    init(_ path: String, create: Bool = false, privateMode: Bool = false) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw FileSafety.error("Invalid directory path")
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw FileSafety.posixError() }
        do {
            for part in path.split(separator: "/").map(String.init) {
                if create, mkdirat(current, part, privateMode ? 0o700 : 0o755) != 0, errno != EEXIST {
                    throw FileSafety.posixError()
                }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw FileSafety.posixError() }
                close(current)
                current = next
            }
            fd = current
        } catch {
            close(current)
            throw error
        }
    }
    deinit { close(fd) }
}

enum FileSafety {
    static func validateFilePath(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"),
              !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw error("Invalid file path")
        }
    }

    /// Bound reads and reject links/devices/FIFOs before consuming serialized state.
    static func readFile(_ path: String, limit: Int) throws -> Data {
        try validateFilePath(path)
        let ns = path as NSString
        let parent = try DirectoryHandle(ns.deletingLastPathComponent)
        let fd = openat(parent.fd, ns.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var st = stat()
        guard limit >= 0, fstat(fd, &st) == 0, isRegularFile(st),
              st.st_size >= 0, st.st_size <= limit else { throw error("Invalid or oversized file") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            guard count <= limit - data.count else { throw error("File exceeded read limit") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func appendLog(_ data: Data, to path: String, limit: Int = 524288) throws {
        try validateFilePath(path)
        guard limit > 0 else { throw error("Invalid log limit") }
        let ns = path as NSString
        let parent = try DirectoryHandle(ns.deletingLastPathComponent)
        let fd = openat(parent.fd, ns.lastPathComponent,
                        O_CREAT | O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, isRegularFile(st), st.st_nlink == 1 else {
            throw error("Invalid log file")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw posixError() }
        defer { flock(fd, LOCK_UN) }
        guard fstat(fd, &st) == 0, st.st_nlink == 1 else { throw error("Log changed before append") }
        guard fchmod(fd, 0o600) == 0 else { throw posixError() }
        let value = data.suffix(limit)
        if st.st_size > limit - value.count {
            guard ftruncate(fd, 0) == 0 else { throw posixError() }
        }
        try value.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }

    static func error(_ description: String) -> NSError {
        NSError(domain: "JustCleaner.FileSafety", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
    static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    /// Atomic same-volume rename, never copy-and-delete or replace a destination.
    static func move(_ source: String, to destination: String, expected: stat? = nil) throws {
        try validateFilePath(source)
        try validateFilePath(destination)
        let src = source as NSString, dst = destination as NSString
        let sourceParent = try DirectoryHandle(src.deletingLastPathComponent)
        let destinationParent = try DirectoryHandle(dst.deletingLastPathComponent)
        var st = stat(), target = stat()
        guard fstatat(sourceParent.fd, src.lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(destinationParent.fd, &target) == 0 else { throw posixError() }
        guard !isLink(st) else { throw error("Source became a symbolic link") }
        if let expected {
            guard st.st_dev == expected.st_dev, st.st_ino == expected.st_ino,
                  st.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec,
                  st.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec else {
                throw error("Source changed during validation; scan again")
            }
        }
        guard st.st_dev == target.st_dev else { throw error("Cross-volume moves are refused; source left in place") }
        guard renameatx_np(sourceParent.fd, src.lastPathComponent,
                           destinationParent.fd, dst.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError()
        }
    }

    static func createDirectory(_ path: String, privateMode: Bool = false) throws {
        _ = try DirectoryHandle(path, create: true, privateMode: privateMode)
    }

    /// Remove entries relative to pinned parents; never traverse a link or mount.
    static func removeTree(_ path: String) throws {
        try validateFilePath(path)
        let ns = path as NSString
        let parent = try DirectoryHandle(ns.deletingLastPathComponent)
        var root = stat()
        guard fstat(parent.fd, &root) == 0 else { throw posixError() }
        try removeEntry(ns.lastPathComponent, parent: parent.fd, device: root.st_dev)
    }

    private static func removeEntry(_ name: String, parent: Int32, device: dev_t) throws {
        var st = stat()
        guard fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
        guard st.st_dev == device else { throw error("Refusing removal across a mounted volume") }
        if isDirectory(st) {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixError() }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else {
                throw error("Directory changed during removal")
            }
            let listing = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard listing >= 0 else { throw posixError() }
            guard let stream = fdopendir(listing) else { close(listing); throw posixError() }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw posixError() }
                    break
                }
                let child = Sizer.direntName(entry)
                if child != "." && child != ".." { try removeEntry(child, parent: fd, device: device) }
            }
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
                throw error("Directory changed during removal")
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posixError() }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw posixError() }
        }
    }

    /// Only empty structural directories may be removed by Undo. Unknown files
    /// are never inferred to be disposable from their absence in a manifest.
    static func pruneEmptyDirectories(_ path: String) -> Bool {
        guard let dir = try? DirectoryHandle(path) else { return false }
        let listing = fcntl(dir.fd, F_DUPFD_CLOEXEC, 0)
        guard listing >= 0 else { return false }
        guard let stream = fdopendir(listing) else { close(listing); return false }
        defer { closedir(stream) }
        var empty = true
        while let entry = readdir(stream) {
            let name = Sizer.direntName(entry)
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(dir.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, isDirectory(st) else {
                empty = false; continue
            }
            if !pruneEmptyDirectories(path + "/" + name) || unlinkat(dir.fd, name, AT_REMOVEDIR) != 0 { empty = false }
        }
        return empty
    }

    /// Flush a private temporary file before publishing its name. This protects
    /// the move journal from process crashes; it is not a power-loss guarantee.
    static func writeJournal(_ data: Data, to path: String) throws {
        try validateFilePath(path)
        let ns = path as NSString
        let parent = try DirectoryHandle(ns.deletingLastPathComponent)
        let name = ".journal-" + UUID().uuidString
        let fd = openat(parent.fd, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd); unlinkat(parent.fd, name, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        guard renameat(parent.fd, name, parent.fd, ns.lastPathComponent) == 0 else { throw posixError() }
    }
}
