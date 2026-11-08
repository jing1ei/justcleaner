import Foundation

// The same binary also answers from Terminal. Handy for the curious, essential
// for testing, and it means a Mac can be tidied over SSH with no screen.

enum CLI {

    static let isTTY = isatty(STDOUT_FILENO) == 1

    static func c(_ code: String, _ text: String) -> String {
        isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ t: String) -> String { c("1", t) }
    static func dim(_ t: String) -> String { c("2", t) }
    static func green(_ t: String) -> String { c("32", t) }
    static func yellow(_ t: String) -> String { c("33", t) }
    static func purple(_ t: String) -> String { c("35", t) }

    static func riskColor(_ r: Risk, _ text: String) -> String {
        switch r {
        case .safe: return green(text)
        case .slower: return yellow(text)
        case .review: return purple(text)
        case .info: return dim(text)
        }
    }

    static func run(_ args: [String]) -> Int32 {
        let verb = args.first ?? "help"
        let flags = Set(args.dropFirst().filter { $0.hasPrefix("--") })
        let options: [String: Set<String>] = [
            "scan": ["--deep", "--json"], "check": ["--deep", "--json"],
            "clean": ["--dry-run", "--only", "--yes", "--rescan"],
            "auto": ["--dry-run", "--only", "--yes", "--rescan"],
            "report": ["--open", "--rescan"], "undo": [], "net": [], "quarantine": [],
            "purge": ["--all", "--older-than"], "doctor": [], "login-item": ["--off"],
            "pack": ["--to"], "version": [], "--version": [], "help": [], "--help": [], "-h": []]
        guard let allowed = options[verb] else { print("Unknown command: " + verb); return 2 }
        var index = 1
        while index < args.count {
            let option = args[index]
            guard allowed.contains(option) else { print("Unknown option: " + option); return 2 }
            if ["--only", "--older-than", "--to"].contains(option) {
                index += 1
                guard index < args.count, !args[index].isEmpty, !args[index].hasPrefix("--") else {
                    print("Missing value for " + option); return 2
                }
                if option == "--older-than" {
                    guard let days = Double(args[index]), days.isFinite, days >= 0 else {
                        print("--older-than must be a nonnegative number"); return 2
                    }
                }
                if option == "--only" {
                    let ids = args[index].split(separator: ",")
                    guard !ids.isEmpty, ids.allSatisfy({ Catalog.spec(String($0)) != nil }) else {
                        print("Unknown or empty category list"); return 2
                    }
                }
            }
            index += 1
        }
        if ["clean", "auto", "purge"].contains(verb), let issue = Config.loadIssue {
            print(issue); return 1
        }
        let cfg = Config.load()

        func value(_ name: String) -> String? {
            guard let index = args.firstIndex(of: "--" + name),
                  index + 1 < args.count else { return nil }
            return args[index + 1]
        }

        switch verb {
        case "scan", "check":
            let deep = flags.contains("--deep") || verb == "check"
            let result = JunkScanner.scan(deep: deep, cfg: cfg)
            if flags.contains("--json") {
                printJSON(result)
            } else {
                printScan(result, cfg: cfg)
            }
            return 0

        case "clean", "auto":
            var scan = JunkScanner.loadLast()
            if scan == nil || flags.contains("--rescan")
                || nowTS() - (scan?.finishedAt ?? 0) > 1800 {
                scan = JunkScanner.scan(deep: false, cfg: cfg)
            }
            guard let s = scan else { return 1 }
            var ids: Set<String>? = nil
            if let only = value("only") {
                ids = Set(only.split(separator: ",").map(String.init))
            }
            let dryRun = flags.contains("--dry-run")
            let plan = Cleaner.plan(s, includeIDs: ids)
            let brewRequested = cfg.includeHomebrewCleanup && ids == nil && s.homebrewFreeableBytes > 0
            if plan.items.isEmpty && !brewRequested {
                print(green("Nothing to clean."))
                for line in plan.skipped { print("  " + yellow("skipped: " + line)) }
                return 0
            }
            let total = plan.bytes + (brewRequested ? s.homebrewFreeableBytes : 0)
            print("")
            print(bold(dryRun ? "PREVIEW — nothing will be touched"
                              : "About to clean \(human(total))"))
            print("")
            var byCategory: [String: (Int64, Int)] = [:]
            for item in plan.items {
                var entry = byCategory[item.categoryTitle] ?? (0, 0)
                entry.0 += item.bytes
                entry.1 += 1
                byCategory[item.categoryTitle] = entry
            }
            for (title, entry) in byCategory.sorted(by: { $0.value.0 > $1.value.0 }) {
                print("  \(title.padded(46)) \(human(entry.0).padded(10)) \(dim("\(entry.1) place(s)"))")
            }
            if brewRequested { print("  Homebrew cleanup estimate: " + human(s.homebrewFreeableBytes)) }
            for line in plan.skipped {
                print("  " + yellow("skipped: " + line))
            }
            print("")
            if dryRun {
                print(dim("Run without --dry-run to do it."))
                return 0
            }
            if !flags.contains("--yes"), isatty(STDIN_FILENO) != 1 || !isTTY {
                print("Noninteractive cleanup requires --yes. Use --dry-run to preview.")
                return 2
            }
            if isTTY, isatty(STDIN_FILENO) == 1, !flags.contains("--yes") {
                print("Everything here is moved to the safety net first, "
                      + dim("retained items are recoverable for \(Int(cfg.keepDays)) day(s); safe items may be erased immediately."))
                print("Go ahead? [y/N] ", terminator: "")
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if answer != "y" && answer != "yes" {
                    print(dim("Left as it was."))
                    return 0
                }
            }
            let outcome = Cleaner.apply(plan.items, cfg: cfg,
                                        runHomebrew: brewRequested)
            print(green("Cleaned \(human(outcome.movedBytes + outcome.brewFreedBytes))")
                  + dim(" · estimated \(human(outcome.freedNowBytes)) removed"
                        + ", \(human(outcome.parkedBytes)) recoverable for \(Int(cfg.keepDays)) day(s)"))
            if outcome.failedCount > 0 {
                print(yellow("\(outcome.failedCount) place(s) could not be moved."))
            }
            for app in outcome.skippedBecauseRunning { print("Left alone: " + app + " is running") }
            _ = JunkScanner.scan(deep: false, cfg: cfg)
            return outcome.failedCount > 0 ? 1 : 0

        case "report":
            // A report is worth nothing if it describes a Mac from last week, and
            // the interesting half of it only exists after a deep look.
            var scan = JunkScanner.loadLast()
            if scan == nil || flags.contains("--rescan") || !(scan?.isDeep ?? false)
                || nowTS() - (scan?.finishedAt ?? 0) > 1800 {
                scan = JunkScanner.scan(deep: true, cfg: cfg)
            }
            guard let s = scan else { return 1 }
            let path: String
            do { path = try Report.write(s, cfg: cfg) }
            catch { print("Could not save report: " + error.localizedDescription); return 1 }
            print(path)
            if flags.contains("--open") {
                guard runCommand("/usr/bin/open", [path], timeout: 10).code == 0 else { return 1 }
            }
            return 0

        case "undo":
            guard let batch = Quarantine.batches().first(where: { $0.isRestorable }) else {
                print("Nothing in the safety net.")
                return 0
            }
            let r = Quarantine.restore(batch)
            print("Restored \(r.restored) place(s) from \(batch.name)"
                  + (r.failed > 0 ? ", \(r.failed) failed" : ""))
            return r.failed > 0 ? 1 : 0

        case "net", "quarantine":
            let batches = Quarantine.batches()
            if batches.isEmpty {
                print("The safety net is empty.")
                return 0
            }
            for b in batches {
                print("\(b.name)  \(human(b.bytes).padded(10)) "
                      + dim("\(b.manifest?.moved.count ?? 0) place(s), \(formatAge(b.createdAt))"))
            }
            print("")
            print(dim("Total \(human(Quarantine.totalBytes()))"))
            return 0

        case "purge":
            let result = flags.contains("--all")
                ? Quarantine.purgeAll()
                : Quarantine.purge(olderThanDays: Double(value("older-than") ?? "") ?? cfg.keepDays)
            print(result.summary)
            return result.failed > 0 ? 1 : 0

        case "doctor":
            return doctor(cfg)

        case "login-item":
            if flags.contains("--off") {
                guard LoginItem.disable() else { print("Could not disable start at login."); return 1 }
                print("JustCleaner will not start automatically.")
            } else {
                guard LoginItem.enable() else { print("Could not enable start at login."); return 1 }
                print("JustCleaner will start when you log in.")
            }
            return 0

        case "pack":
            switch SharePackager.pack(destinationDir: value("to")) {
            case .success(let path):
                print(path)
                return 0
            case .failure(let message):
                print("Failed: " + message)
                return 1
            }

        case "version", "--version":
            print("JustCleaner " + JustCleanerVersion.string)
            return 0

        default:
            print("""
            JustCleaner \(JustCleanerVersion.string) — keeps a Mac tidy without drama.

            Usually you just click the sparkle icon in the menu bar. From here:

              scan [--deep] [--json]     look, change nothing
              clean [--dry-run]          clean the safe things
                    [--only id,id]       only these categories
                    [--yes]              do not ask first
                    [--rescan]           look again before cleaning
              report [--open]            write the full HTML explanation
              undo                       put the last cleanup back
              net                        what is in the safety net
              purge [--all]              release that space for good
                    [--older-than N]
              doctor                     prove the safety rules still work
              login-item [--off]         start automatically, or not
              pack [--to DIR]            make a copy for another Mac
              version

            Nothing is deleted where it sits: it is moved to ~/.justcleaner/quarantine
            first. Safe items may then be erased immediately; `undo` restores retained items.
            """)
            return 0
        }
    }

    // MARK: - output

    static func printScan(_ s: ScanResult, cfg: Config) {
        print("")
        print(bold("  \(s.machine) · JustCleaner \(JustCleanerVersion.string) · \(s.mode) look"))
        if let d = s.disk {
            let pct = Double(d.used) / Double(d.total) * 100
            print(dim("  disk: \(human(d.free)) free of \(human(d.total)) "
                      + "(\(String(format: "%.0f", pct))% used)"))
        }
        print("")
        var groups: [String] = []
        for c in s.categories where !groups.contains(c.group) { groups.append(c.group) }
        for group in groups {
            print(bold("  " + group))
            for cat in s.categories where cat.group == group {
                print("    " + riskColor(cat.risk, cat.title.padded(48))
                      + human(cat.bytes).padded(10)
                      + dim(cat.risk.label))
                for item in cat.items.prefix(3) {
                    print(dim("        " + tildePath(item.path).padded(56) + human(item.bytes)))
                }
                if cat.items.count > 3 {
                    print(dim("        … \(cat.items.count - 3) more"))
                }
            }
            print("")
        }
        if s.homebrewFreeableBytes > 0 {
            print("  " + yellow("Homebrew could free about \(human(s.homebrewFreeableBytes)) itself"))
            print("")
        }
        print("  " + bold("Cleanable now: " + human(s.readyBytes)))
        if let sentence = s.blockedSentence {
            print("  " + yellow("Held by open apps: " + human(s.blockedBytes)
                                + " · " + sentence))
        }
        if s.decisionBytes > 0 {
            print("  " + purple("Your call:     " + human(s.decisionBytes)))
        }
        if s.quarantineBytes > 0 {
            print("  " + dim("Safety net:    " + human(s.quarantineBytes)))
        }
        for w in s.warnings { print("\n  " + yellow(w)) }
        print("")
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(value),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func doctor(_ cfg: Config) -> Int32 {
        print("")
        print(bold("  Safety self-test"))
        print("")
        var failures = 0
        for testCase in Safety.selfTestCases() {
            let verdict = Safety.check(testCase.path, kind: testCase.kind)
            let allowed = verdict.isOK
            let pass = allowed == testCase.mustBeAllowed
            if !pass { failures += 1 }
            let mark = pass ? green("ok  ") : "\u{1B}[31mFAIL\u{1B}[0m"
            let expectation = testCase.mustBeAllowed ? "may be cleaned" : "protected"
            print("  \(mark) \(tildePath(testCase.path).padded(52)) "
                  + dim("\(expectation)\(allowed ? "" : " – " + verdict.reason)"))
        }
        print("")
        if failures == 0 {
            print("  " + green("All \(Safety.selfTestCases().count) rules behave as intended."))
        } else {
            print("  \u{1B}[31m\(failures) rule(s) misbehaved. Do not clean anything.\u{1B}[0m")
        }
        print("")
        print(bold("  This Mac"))
        let env = EnvironmentReport.collect()
        for t in env.tools {
            print("    \(t.name.padded(10)) \((t.version.isEmpty ? "-" : t.version).padded(10))"
                  + dim(tildePath(t.path)))
        }
        if !env.duplicates.isEmpty {
            print("")
            print("  " + yellow("Installed more than once:"))
            for d in env.duplicates { print("    " + d) }
        }
        if !env.music.apps.isEmpty {
            print("")
            print("  " + green("Music software protected: " + env.music.apps.joined(separator: ", ")))
        }
        print("")
        print(dim("  Safety net keeps items \(Int(cfg.keepDays)) day(s) · quarantine at "
                  + tildePath(Paths.quarantineDir)))
        print("")
        return failures == 0 ? 0 : 1
    }
}
