import Foundation

// Plain-language formatting helpers. Everything a human reads goes through here.

/// Read the current time for each age and expiry calculation.
@inline(__always) func nowTS() -> Double { Date().timeIntervalSince1970 }

let kDAY: Double = 86_400

func human(_ bytes: Int64) -> String {
    let n = Double(bytes)
    if n < 1024 { return "\(Int(n)) B" }
    var v = n
    for unit in ["KB", "MB", "GB", "TB"] {
        v /= 1024
        if v < 1024 || unit == "TB" {
            if v < 10 { return String(format: "%.2f %@", v, unit) }
            if v < 100 { return String(format: "%.1f %@", v, unit) }
            return String(format: "%.0f %@", v, unit)
        }
    }
    return String(format: "%.0f TB", v)
}

/// Short form used in the menu bar itself, where every pixel counts.
func humanShort(_ bytes: Int64) -> String {
    let n = Double(bytes)
    if n < 1024 * 1024 { return "0 MB" }
    let mb = n / (1024 * 1024)
    if mb < 1024 { return String(format: "%.0f MB", mb) }
    let gb = mb / 1024
    if gb < 10 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f GB", gb)
}

func daysAgo(_ ts: Double) -> Double? {
    if !ts.isFinite || ts <= 0 { return nil }
    return max(0, (nowTS() - ts) / kDAY)
}

func formatAge(_ ts: Double) -> String {
    guard let d = daysAgo(ts) else { return "unknown" }
    if d < 1 { return "today" }
    if d < 2 { return "yesterday" }
    if d < 45 { return "\(Int(d)) days ago" }
    if d < 400 { return "\(Int(d / 30)) months ago" }
    return String(format: "%.1f years ago", d / 365)
}

func tildePath(_ path: String) -> String {
    if path == Paths.home { return "~" }
    if path.hasPrefix(Paths.home + "/") {
        return "~" + path.dropFirst(Paths.home.count)
    }
    return path
}

func stamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    return f.string(from: Date())
}

func humanDate(_ ts: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "d MMM yyyy, HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date(timeIntervalSince1970: ts))
}

extension String {
    /// "quit Lark to free 4 GB more" → "Quit Lark to free 4 GB more".
    /// `capitalized` would lowercase the rest of the sentence; this does not.
    var sentenceCased: String {
        guard let f = first else { return self }
        return String(f).uppercased() + dropFirst()
    }

    func padded(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}

/// Statistics saturate rather than overflowing when old state is malformed.
func addBytes(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
    return overflow ? Int64.max : value
}
