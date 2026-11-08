import Foundation

enum MenuPresentation {
    static func cleanTitle(_ scan: ScanResult?, busy: Bool) -> String {
        if busy { return "Working…" }
        guard let scan else { return "Scan before cleaning" }
        if scan.readyBytes > 0 { return "Clean up  ·  " + human(scan.readyBytes) }
        if scan.blockedBytes > 0 { return "Caches are in use" }
        return "No removable caches found"
    }

    static func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit >= 5 else { return text }
        let head = (limit - 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(limit - head - 1))
    }

    static func categoryTitle(_ cat: CategoryResult) -> String {
        let names = ["package-caches": "Package downloads", "xcode": "Xcode build caches",
            "ai-tools": "Coding tool caches", "app-caches": "App data caches",
            "browser-caches": "Browser caches", "updater-leftovers": "Downloaded app updates",
            "library-caches": "App caches", "project-builds": "Project dependencies and builds",
            "agent-runtimes": "Assistant runtimes", "ai-models": "AI models",
            "ai-history": "AI chat history", "big-things": "Large folders", "misc": "macOS caches"]
        return names[cat.id] ?? cat.title
    }
}
