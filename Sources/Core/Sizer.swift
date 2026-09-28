import Foundation

@inline(__always) func isRegularFile(_ st: stat) -> Bool {
    (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
}

@inline(__always) func isDirectory(_ st: stat) -> Bool {
    (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
}

@inline(__always) func isLink(_ st: stat) -> Bool {
    (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
}

struct Measurement {
    var bytes: Int64 = 0
    var files: Int = 0
    var newest: Double = 0
    var partial: Bool = false
    var denied: Bool = false
}

enum Sizer {

    static let skipDirNames: Set<String> = [
        ".Trash", "CloudStorage", "Photos Library.photoslibrary",
        "Mobile Documents", "Keychains",
    ]

    @inline(__always)
    static func direntName(_ e: UnsafeMutablePointer<dirent>) -> String {
        var copy = e.pointee
        return withUnsafeBytes(of: &copy.d_name) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Size of one file or the whole tree below one folder.
    static func measure(_ path: String, budget: Double = 6.0) -> Measurement? {
        var out = Measurement()
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        if isLink(st) { return nil }
        if !isDirectory(st) {
            out.bytes = Int64(st.st_blocks) * 512
            out.files = 1
            out.newest = Double(st.st_mtimespec.tv_sec)
            return out
        }
        out.newest = Double(st.st_mtimespec.tv_sec)

        let deadline = Date().addingTimeInterval(budget)
        var checked = 0
        var seenFiles = Set<String>()
        var stack: [String] = [path]
        while let current = stack.popLast() {
            // Bound wide directories as well as deep trees.
            checked += 1
            if Date() > deadline {
                out.partial = true
                break
            }
            var directoryStat = stat()
            guard lstat(current, &directoryStat) == 0, isDirectory(directoryStat) else {
                out.partial = true
                continue
            }
            out.newest = max(out.newest, Double(directoryStat.st_mtimespec.tv_sec))
            guard let dir = opendir(current) else {
                out.partial = true
                if errno == EPERM || errno == EACCES { out.denied = true }
                continue
            }
            while let entry = readdir(dir) {
                checked += 1
                if checked % 256 == 0, Date() > deadline {
                    out.partial = true
                    break
                }
                let name = direntName(entry)
                if name == "." || name == ".." { continue }
                let child = current + "/" + name
                let type = Int32(entry.pointee.d_type)
                if type == DT_LNK { continue }
                if type == DT_DIR {
                    if skipDirNames.contains(name) { continue }
                    stack.append(child)
                    continue
                }
                if type == DT_REG || type == DT_UNKNOWN {
                    var cst = stat()
                    guard lstat(child, &cst) == 0 else { continue }
                    if isLink(cst) { continue }
                    if isDirectory(cst) {
                        if !skipDirNames.contains(name) { stack.append(child) }
                    } else {
                        if cst.st_nlink > 1, !seenFiles.insert("\(cst.st_dev):\(cst.st_ino)").inserted { continue }
                        out.bytes += Int64(cst.st_blocks) * 512
                        out.files += 1
                        let m = Double(cst.st_mtimespec.tv_sec)
                        if m > out.newest { out.newest = m }
                    }
                }
            }
            closedir(dir)
            if out.partial { break }
        }
        return out
    }

    static func listDir(_ path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = direntName(entry)
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names.sorted()
    }

    static func isDir(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return isDirectory(st)
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Free / total space of the disk the home folder lives on.
    static func diskInfo() -> (total: Int64, free: Int64, used: Int64)? {
        let url = URL(fileURLWithPath: Paths.home)
        guard let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return nil }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let free = min(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0), total)
        if total == 0 { return nil }
        return (total, Int64(free), total - Int64(free))
    }
}
