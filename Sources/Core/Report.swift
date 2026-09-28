import Foundation

enum Report {

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let glossary: [(String, String)] = [
        ("Cache", "A copy of something an app already worked out once, kept so that it does not have to do the work again. Apps normally rebuild caches when needed. Review unfamiliar folders before removing them."),
        ("node_modules", "The folder where a JavaScript project keeps every library it borrowed. One project can easily borrow 40,000 files. It is rebuilt by running one command inside the project, but check for local changes first. Reinstall dependencies before running the project again."),
        ("Homebrew", "A tool that installs command line software. It keeps every installer it has ever downloaded, and old versions of everything, unless asked to tidy up."),
        ("Xcode DerivedData", "Apple's build workshop. Everything in it is intermediate: it is rebuilt from your project whenever you build again."),
        ("Virtual environment (.venv)", "A private copy of Python for one project. Re-creatable from a list of names kept in the project."),
        ("Quarantine, or safety net", "JustCleaner's waiting room. Nothing is deleted where it sits: it is moved here first, and retained items can be restored until expiry. Immediately erased items cannot be undone."),
        ("Full Disk Access", "An optional macOS permission that allows more folders to be measured. It does not disable JustCleaner's protected-file rules."),
    ]

    // MARK: - style

    private static let css = """
    :root {
      --paper: #faf8f4;
      --paper-2: #fffefb;
      --ink: #1a1815;
      --ink-soft: #6f6a61;
      --ink-faint: #756e64;
      --line: #e6e1d8;
      --line-soft: #efebe3;
      --brass: #9a7b45;
      --sage: #5d7a5e;
      --clay: #a8663f;
      --slate: #5a6b80;
      color-scheme: light dark;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --paper: #0f0f0e;
        --paper-2: #161614;
        --ink: #f0ece4;
        --ink-soft: #9b958a;
        --ink-faint: #a49d92;
        --line: #292824;
        --line-soft: #211f1c;
        --brass: #c9a468;
        --sage: #8fae8f;
        --clay: #d08f63;
        --slate: #91a5bd;
      }
    }
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body {
      margin: 0;
      padding: 88px 32px 140px;
      background: var(--paper);
      color: var(--ink);
      font: 400 15.5px/1.7 ui-sans-serif, -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      -webkit-font-smoothing: antialiased;
      font-feature-settings: "kern" 1;
    }
    .wrap { max-width: 780px; margin: 0 auto; }

    /* type */
    .eyebrow {
      font-size: 10.5px; letter-spacing: 0.22em; text-transform: uppercase;
      color: var(--ink-faint); margin: 0 0 18px;
    }
    h1 {
      font: 300 46px/1.12 ui-serif, "New York", Iowan Old Style, Palatino, Georgia, serif;
      letter-spacing: -0.015em; margin: 0 0 14px;
    }
    h2 {
      font: 300 15px/1.4 ui-sans-serif, -apple-system, sans-serif;
      letter-spacing: 0.2em; text-transform: uppercase;
      color: var(--ink-faint);
      margin: 0 0 22px; padding-bottom: 12px;
      border-bottom: 1px solid var(--line);
    }
    h3 {
      font: 400 19px/1.35 ui-serif, "New York", Iowan Old Style, Palatino, Georgia, serif;
      margin: 0; letter-spacing: -0.005em;
    }
    p { margin: 0 0 12px; }
    .lede { color: var(--ink-soft); font-size: 15px; margin: 0 0 4px; max-width: 62ch; }
    .muted { color: var(--ink-soft); }
    .faint { color: var(--ink-faint); }
    section { margin: 62px 0 0; }
    .rule { height: 1px; background: var(--line); border: 0; margin: 0; }

    /* numbers */
    .num { font-variant-numeric: tabular-nums; font-feature-settings: "tnum" 1; }
    .size { font: 400 17px/1.3 ui-serif, "New York", Palatino, Georgia, serif;
            font-variant-numeric: tabular-nums; white-space: nowrap; }
    .hero { font: 300 34px/1.15 ui-serif, "New York", Palatino, Georgia, serif;
            font-variant-numeric: tabular-nums; letter-spacing: -0.01em; }

    /* layout helpers */
    .row { display: flex; justify-content: space-between; align-items: baseline; gap: 20px; }
    .block { padding: 22px 0; border-bottom: 1px solid var(--line-soft); }
    .block:last-child { border-bottom: 0; }
    .figure { display: flex; justify-content: space-between; align-items: baseline;
              gap: 24px; padding: 15px 0; border-bottom: 1px solid var(--line-soft); }
    .figure:last-child { border-bottom: 0; }
    .figure .label { font-size: 15px; }
    .figure .note { display: block; color: var(--ink-soft); font-size: 13px; line-height: 1.55; max-width: 54ch; }

    /* disk bar */
    .bar { display: flex; height: 3px; margin: 26px 0 14px; background: var(--line);
           border-radius: 2px; overflow: hidden; }
    .bar i { display: block; height: 100%; }
    .legend { display: flex; flex-wrap: wrap; gap: 18px; font-size: 12.5px; color: var(--ink-soft); }
    .legend b { font-weight: 400; }
    .swatch { display: inline-block; width: 18px; height: 3px; border-radius: 2px;
              vertical-align: 3px; margin-right: 7px; }

    /* tags */
    .tag {
      display: inline-block; font-size: 10.5px; letter-spacing: 0.14em;
      text-transform: uppercase; padding: 3px 0; margin-top: 10px;
      color: var(--ink-faint); border-top: 1px solid currentColor; min-width: 92px;
    }
    .safe   { color: var(--sage); }
    .slower { color: var(--brass); }
    .review { color: var(--clay); }
    .info   { color: var(--slate); }

    /* tables */
    table { width: 100%; border-collapse: collapse; margin: 14px 0 0; font-size: 13px; }
    th { text-align: left; font-weight: 400; font-size: 10.5px; letter-spacing: 0.14em;
         text-transform: uppercase; color: var(--ink-faint);
         padding: 0 10px 8px 0; border-bottom: 1px solid var(--line); }
    th:last-child, td:last-child { padding-right: 0; }
    td { padding: 9px 10px 9px 0; border-bottom: 1px solid var(--line-soft);
         vertical-align: top; color: var(--ink-soft); }
    tr:last-child td { border-bottom: 0; }
    td.p { color: var(--ink); }
    td.n { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; color: var(--ink); }
    code {
      font: 400 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
      color: var(--ink); word-break: break-all;
    }

    nav { display:flex; flex-wrap:wrap; gap:10px 20px; margin-top:24px; }
    a { color:var(--ink); text-decoration-color:var(--brass); text-underline-offset:4px; }
    summary { cursor:pointer; color:var(--ink); padding:12px 0; }
    :focus-visible { outline:2px solid var(--brass); outline-offset:4px; }
    h1, h3, td { overflow-wrap:anywhere; }
    /* quiet panels */
    .panel { background: var(--paper-2); border: 1px solid var(--line);
             border-radius: 2px; padding: 24px 26px; }
    .panel.accent { border-left: 2px solid var(--brass); }
    .list { margin: 12px 0 0; padding: 0; list-style: none; }
    .list li { position: relative; padding: 5px 0 5px 18px; color: var(--ink-soft); font-size: 14px; }
    .list li::before { content: ""; position: absolute; left: 0; top: 14px;
                       width: 7px; height: 1px; background: var(--brass); }
    .terms { margin: 0; }
    .terms dt { font: 400 15px/1.5 ui-serif, "New York", Palatino, Georgia, serif; margin: 18px 0 3px; }
    .terms dt:first-child { margin-top: 0; }
    .terms dd { margin: 0; color: var(--ink-soft); font-size: 13.5px; max-width: 64ch; }

    footer { margin: 96px 0 0; padding-top: 20px; border-top: 1px solid var(--line);
             font-size: 12px; color: var(--ink-faint); }

    @media (max-width: 620px) {
      body { padding: 56px 20px 96px; }
      h1 { font-size: 34px; }
      .figure, .row { flex-direction: column; gap: 6px; }
      table { display: block; overflow-x: auto; }
      h3 { overflow-wrap: anywhere; }
      .hero { font-size: 27px; }
    }
    @media print {
      body { background: #fff; color: #000; padding: 0; }
      .panel { background: #fff; }
      section { break-inside: avoid; }
    }
    """

    // MARK: - page

    static func html(_ scan: ScanResult, cfg: Config) -> String {
        var h = ""
        h += """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>JustCleaner · \(escape(scan.machine))</title>
        <style>\(css)</style></head><body><div class="wrap">
        """

        // ---- masthead ----
        h += "<p class=\"eyebrow\">JustCleaner \(JustCleanerVersion.string) · \(scan.isDeep ? "deep look" : "quick look")</p>"
        h += "<h1>What is on<br>\(escape(scan.machine))</h1>"
        h += "<p class=\"lede\">Written for \(escape(scan.user)) on \(escape(humanDate(scan.finishedAt))). "
        h += "This report is saved on your Mac. No files were cleaned to produce it.</p>"
        h += "<nav aria-label=\"Report sections\"><a href=\"#summary\">Overview</a><a href=\"#details\">Cleanup details</a><a href=\"#protected\">Protected files</a><a href=\"#glossary\">Glossary</a></nav>"

        // ---- disk ----
        if let d = scan.disk, d.total > 0 {
            let usedPct = Double(d.used) / Double(d.total) * 100
            let readyPct = min(Double(scan.readyBytes) / Double(d.total) * 100, usedPct)
            let blockedPct = min(Double(scan.blockedBytes) / Double(d.total) * 100, usedPct - readyPct)
            let inUsePct = max(usedPct - readyPct - blockedPct, 0)
            h += "<section><h2>The disk</h2>"
            h += "<div class=\"row\"><span class=\"hero\">\(human(d.free)) free</span>"
            h += "<span class=\"size faint\">\(String(format: "%.0f", usedPct))% of \(human(d.total)) used</span></div>"
            h += "<div class=\"bar\">"
            h += "<i style=\"width:\(pc(inUsePct));background:var(--ink)\"></i>"
            h += "<i style=\"width:\(pc(readyPct));background:var(--sage)\"></i>"
            h += "<i style=\"width:\(pc(blockedPct));background:var(--brass)\"></i></div>"
            h += "<div class=\"legend\">"
            h += "<span><i class=\"swatch\" style=\"background:var(--ink)\"></i><b>In use</b> \(human(max(d.used - scan.cleanableBytes, 0)))</span>"
            h += "<span><i class=\"swatch\" style=\"background:var(--sage)\"></i><b>Ready to clean</b> \(human(scan.readyBytes))</span>"
            if scan.blockedBytes > 0 {
                h += "<span><i class=\"swatch\" style=\"background:var(--brass)\"></i><b>Clearable once apps are closed</b> \(human(scan.blockedBytes))</span>"
            }
            h += "<span><i class=\"swatch\" style=\"background:var(--line)\"></i><b>Free</b> \(human(d.free))</span>"
            h += "</div></section>"
        }

        // ---- headline numbers ----
        h += "<section id=\"summary\"><h2>The short version</h2>"
        h += figure("Ready to clean", human(scan.readyBytes),
                    "Estimated cache and log sizes. Retained items occupy space until the safety net expires.")
        if scan.blockedBytes > 0 {
            h += figure("Held by an app you have open", human(scan.blockedBytes),
                        (scan.blockedSentence?.sentenceCased ?? "Close the app and clean again")
                        + ". Recognized running apps are excluded from cleanup.")
        }
        h += figure("Waiting for your decision", human(scan.decisionBytes),
                    scan.isDeep
                    ? "Project build folders, AI models, chat history and the Trash. Listed, never touched on their own."
                    : "Take a deep look to see this.")
        h += figure("Large folders, shown for information", human(scan.infoBytes),
                    "Read out so you can see where the disk went. Out of reach of every cleaning action.")
        h += figure("Held in the safety net", human(scan.quarantineBytes),
                    "Already removed, still recoverable for \(Int(cfg.keepDays)) day\(Int(cfg.keepDays) == 1 ? "" : "s").")
        if cfg.totalFreedBytes > 0 {
            h += figure("Estimated space released so far", human(cfg.totalFreedBytes),
                        "Estimated from successfully removed files and Homebrew output. Anything still "
                        + "waiting in the safety net is not included here.")
        }
        h += "</section>"

        if !scan.warnings.isEmpty {
            h += "<section><h2>Worth knowing</h2><div class=\"panel accent\">"
            for w in scan.warnings { h += "<p class=\"muted\" style=\"margin:0 0 8px\">\(escape(w))</p>" }
            h += "</div></section>"
        }

        // ---- categories, grouped ----
        h += "<div id=\"details\"></div>"
        var groups: [String] = []
        for c in scan.categories where !groups.contains(c.group) { groups.append(c.group) }
        for group in groups {
            h += "<section><h2>\(escape(group))</h2>"
            for cat in scan.categories where cat.group == group {
                let cls = cat.risk.rawValue
                h += "<div class=\"block\"><div class=\"row\">"
                h += "<h3>\(escape(cat.title))</h3><span class=\"size\">\(human(cat.bytes))</span></div>"
                h += "<p class=\"muted\" style=\"margin:8px 0 0;max-width:62ch;font-size:14px\">\(escape(cat.what))</p>"
                h += "<div><span class=\"tag \(cls)\">\(escape(cat.risk.label))</span></div>"
                if !cat.items.isEmpty {
                    h += "<details><summary>Show all \(cat.items.count) folder(s)</summary><table><tr><th>Folder</th><th>What it is</th><th class=\"n\">Size</th></tr>"
                    for item in cat.items {
                        h += "<tr><td class=\"p\"><code>\(escape(tildePath(item.path)))</code></td>"
                        h += "<td>\(escape(item.note))</td>"
                        h += "<td class=\"n\">\(item.partial ? "at least " : "")\(human(item.bytes))</td></tr>"
                    }
                    h += "</table></details>"
                }
                h += "</div>"
            }
            h += "</section>"
        }

        if scan.homebrewFreeableBytes > 0 {
            h += "<section><h2>Homebrew's own leftovers</h2><div class=\"block\">"
            h += "<div class=\"row\"><h3>Old versions and downloaded installers</h3>"
            h += "<span class=\"size\">\(human(scan.homebrewFreeableBytes))</span></div>"
            h += "<p class=\"muted\" style=\"margin:8px 0 0;max-width:62ch;font-size:14px\">JustCleaner does not "
            h += "delete these itself. It asks Homebrew to tidy up with its own <code>cleanup</code> command, "
            h += "which is why this part does not pass through the safety net.</p>"
            h += "<div><span class=\"tag slower\">Handled by Homebrew</span></div></div></section>"
        }

        // ---- protected ----
        h += "<section id=\"protected\"><h2>Protected, always</h2><div class=\"panel accent\">"
        h += "<p class=\"muted\" style=\"margin:0;max-width:62ch\">These are refused by the safety rules "
        h += "before cleanup. They may still be measured for the report. No setting disables the hard protections.</p><ul class=\"list\">"
        h += "<li>Everything under <code>~/Music</code>: every project, preset, sample library and plug-in folder</li>"
        h += "<li>Personal folders are excluded from automatic cleanup. Recognized project build folders can be reviewed separately when enabled.</li>"
        h += "<li>Known cloud-storage locations, including iCloud and OneDrive</li>"
        h += "<li>Keys, passwords, keychains, Mail, Messages, Safari data, app settings</li>"
        h += "<li>Anything outside your home folder, and the system itself</li></ul>"
        if let env = scan.environment, !env.music.apps.isEmpty {
            h += "<p class=\"faint\" style=\"margin:18px 0 0;font-size:13px\">Music software recognised here: "
            h += escape(env.music.apps.joined(separator: ", ")) + ".</p>"
        }
        if let env = scan.environment, !env.music.folders.isEmpty {
            h += "<table><tr><th>Protected folder</th><th>What it holds</th>"
            h += "<th class=\"n\">Items</th><th class=\"n\">Size</th></tr>"
            for f in env.music.folders.sorted(by: { $0.bytes > $1.bytes }) {
                h += "<tr><td class=\"p\"><code>\(escape(tildePath(f.path)))</code></td>"
                h += "<td>\(escape(f.label))</td>"
                h += "<td class=\"n\">\(f.count)</td><td class=\"n\">\(human(f.bytes))</td></tr>"
            }
            h += "</table>"
        }
        h += "</div></section>"

        // ---- the blind spot, said out loud ----
        if !cfg.scanPersonalFolders {
            h += "<section><h2>One place JustCleaner did not look</h2><div class=\"panel\">"
            h += "<p class=\"muted\" style=\"margin:0;max-width:62ch\">Downloads, Desktop and Documents were "
            h += "not measured at all, so a forgotten 20 GB of installers in Downloads will not appear above. "
            h += "That is deliberate: those are your own files. Turn on "
            h += "<em>Settings › Include Desktop, Documents, Downloads</em> in the menu and JustCleaner will "
            h += "report their size — and only their size. Deleting anything there stays your decision.</p>"
            h += "</div></section>"
        }

        // ---- environment ----
        if let env = scan.environment {
            h += "<section><h2>Your coding environment</h2>"
            if !env.tools.isEmpty {
                h += "<table><tr><th>Tool</th><th>Version</th><th>Where it came from</th><th>What it is for</th></tr>"
                for t in env.tools {
                    h += "<tr><td class=\"p\"><code>\(escape(t.name))</code></td>"
                    h += "<td class=\"num\">\(escape(t.version.isEmpty ? "—" : t.version))</td>"
                    h += "<td>\(escape(t.origin))</td><td>\(escape(t.meaning))</td></tr>"
                }
                h += "</table>"
            }
            if !env.missing.isEmpty {
                h += "<p class=\"faint\" style=\"margin:16px 0 0;font-size:13px\">Not installed: "
                h += escape(env.missing.joined(separator: ", ")) + ".</p>"
            }
            if env.duplicates.isEmpty {
                h += "<p class=\"muted\" style=\"margin:16px 0 0;font-size:13.5px\">No tool is installed twice. "
                h += "That is the tidy case: one command, one place.</p>"
            } else {
                h += "<div class=\"block\" style=\"border:0;padding-bottom:0\"><h3>Installed more than once</h3>"
                h += "<p class=\"muted\" style=\"margin:8px 0 0;max-width:62ch;font-size:14px\">This is the usual "
                h += "reason a project works in one Terminal window and fails in another.</p><ul class=\"list\">"
                for d in env.duplicates { h += "<li><code>\(escape(d))</code></li>" }
                h += "</ul></div>"
            }
            if !env.shellFiles.isEmpty {
                h += "<div class=\"block\" style=\"border:0\"><h3>Startup files of your Terminal</h3><ul class=\"list\">"
                for s in env.shellFiles { h += "<li>\(escape(s))</li>" }
                h += "</ul></div>"
            }
            if !env.loginItems.isEmpty {
                h += "<div class=\"block\" style=\"border:0\"><h3>Helpers that start with your Mac</h3><ul class=\"list\">"
                for l in env.loginItems.prefix(30) { h += "<li>\(escape(l))</li>" }
                if env.loginItems.count > 30 {
                    h += "<li class=\"faint\">and \(env.loginItems.count - 30) more</li>"
                }
                h += "</ul></div>"
            }
            h += "</section>"
        }

        // ---- projects ----
        if !scan.repos.isEmpty {
            h += "<section><h2>Your coding projects</h2>"
            h += "<p class=\"muted\" style=\"margin:0;max-width:62ch;font-size:14px\">Found by looking for git "
            h += "projects in your home folder, newest first. The project itself is never touched — only the "
            h += "folders a build tool can make again.</p>"
            h += "<table><tr><th>Project</th><th>Last change</th><th>Unsaved work</th><th class=\"n\">Size</th></tr>"
            for r in scan.repos.prefix(25) {
                let dirty: String
                switch r.hasUnsavedWork {
                case .some(true):  dirty = "<span class=\"review\">yes — keep</span>"
                case .some(false): dirty = "no"
                default:           dirty = "<span class=\"faint\">unknown</span>"
                }
                h += "<tr><td class=\"p\"><code>\(escape(tildePath(r.path)))</code></td>"
                h += "<td>\(escape(formatAge(r.mtime)))</td><td>\(dirty)</td>"
                h += "<td class=\"n\">\(human(r.bytes))</td></tr>"
            }
            if scan.repos.count > 25 {
                h += "<tr><td colspan=\"4\" class=\"faint\">and \(scan.repos.count - 25) more</td></tr>"
            }
            h += "</table></section>"
        }

        // ---- safety net history ----
        let batches = Quarantine.batches()
        if !batches.isEmpty {
            h += "<section><h2>The safety net</h2>"
            h += "<p class=\"muted\" style=\"margin:0;max-width:62ch;font-size:14px\">Removed items wait here for "
            h += "\(Int(cfg.keepDays)) day\(Int(cfg.keepDays) == 1 ? "" : "s") before the space is released for good. "
            h += "Batches with recovery entries can be restored from the menu. Batches with errors remain available for inspection in Finder.</p>"
            h += "<table><tr><th>Batch</th><th class=\"n\">Places</th><th class=\"n\">Size</th><th>Age</th></tr>"
            for b in batches.prefix(12) {
                h += "<tr><td class=\"p\"><code>\(escape(humanDate(b.createdAt)))</code></td>"
                h += "<td class=\"n\">\(b.manifest?.moved.count ?? 0)</td>"
                h += "<td class=\"n\">\(human(b.bytes))</td>"
                h += "<td>\(escape(formatAge(b.createdAt)))</td></tr>"
            }
            if batches.count > 12 {
                h += "<tr><td colspan=\"4\" class=\"faint\">and \(batches.count - 12) more</td></tr>"
            }
            h += "</table></section>"
        }

        // ---- glossary ----
        h += "<section id=\"glossary\"><h2>Words that keep coming up</h2><dl class=\"terms\">"
        for (term, meaning) in glossary {
            h += "<dt>\(escape(term))</dt><dd>\(escape(meaning))</dd>"
        }
        h += "</dl></section>"

        h += "<footer>JustCleaner \(JustCleanerVersion.string) · settings in <code>~/.mactidy/config.json</code> · "
        h += "log in <code>~/.mactidy/mactidy.log</code><br>This page is a plain file on your Mac. "
        h += "Nothing was uploaded, and it works offline forever.</footer>"
        h += "</div></body></html>"
        return h
    }

    // MARK: - pieces

    private static func pc(_ v: Double) -> String {
        String(format: "%.3f%%", max(v, 0))
    }

    private static func figure(_ title: String, _ size: String, _ note: String) -> String {
        "<div class=\"figure\"><span class=\"label\">\(escape(title))"
        + "<span class=\"note\">\(escape(note))</span></span>"
        + "<span class=\"size\">\(escape(size))</span></div>"
    }

    /// Writes the report and returns its path.
    @discardableResult
    static func write(_ scan: ScanResult, cfg: Config) throws -> String {
        guard Paths.ensureStateDirs() else { throw FileSafety.error("Cannot open JustCleaner’s private storage") }
        let path = Paths.reportsDir + "/report.html"
        try html(scan, cfg: cfg).write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        return path
    }
}
