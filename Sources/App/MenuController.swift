import AppKit

// The whole user interface: one icon, one menu, no windows, no dock icon, no
// notifications. Opening the menu is instant because it always draws the last
// known numbers; a fresh look happens in the background.

final class MenuController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var appearanceObservation: NSKeyValueObservation?
    private var cfg = Config.load()
    private var scan: ScanResult?
    /// Refreshed every time the menu opens, so rows can say "in use".
    private var runningProcesses: Set<String> = []
    private var busyMessage: String?
    private var operationID: UUID?
    private var busyStartedAt: Double = 0
    private var progressDetail = ""
    private var progressTimer: Timer?
    private var needsRebuild = false
    private var batches: [Batch] = []
    private var loadedBatches = false
    private var updatingProcesses = false
    private var disabledStates: [ObjectIdentifier: Bool] = [:]
    /// One line of feedback after an action. It stamps itself so the menu can
    /// stop showing it once it is no longer news.
    private var lastResultLine: String? { didSet { lastResultAt = nowTS() } }
    private var lastResultAt: Double = 0
    private var timer: Timer?
    /// While the menu is on screen it is corrected in place instead of being
    /// rebuilt underneath the pointer.
    private var menuIsOpen = false
    private weak var headlineItem: NSMenuItem?
    private weak var sublineItem: NSMenuItem?
    private weak var blockedItem: NSMenuItem?
    private weak var cleanItem: NSMenuItem?

    init(startAutomatically: Bool = true) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.synchronizeAppearance()
            }
        }
        scan = JunkScanner.loadLast()
        loadBatches()
        redrawIcon()
        rebuild()

        guard startAutomatically else { return }
        // Start promptly; the menu can already describe the pending scan.
        DispatchQueue.main.async { [weak self] in
            self?.refresh(deep: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Menus can have a different presentation context from the menu-bar button.
    /// Use the app's inherited appearance, including accessibility variants.
    private func synchronizeAppearance() {
        applyAppearance(NSApp.effectiveAppearance, to: menu)
        if menuIsOpen { retitleLiveItems() } else { rebuild() }
    }

    private func applyAppearance(_ appearance: NSAppearance, to menu: NSMenu) {
        menu.appearance = appearance
        for item in menu.items {
            if let submenu = item.submenu { applyAppearance(appearance, to: submenu) }
        }
    }

    // MARK: - the icon

    private func redrawIcon() {
        guard let button = statusItem.button else { return }
        let symbol = busyMessage == nil ? "sparkles" : "arrow.triangle.2.circlepath"
        if #available(macOS 11.0, *),
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "JustCleaner") {
            image.isTemplate = true
            button.image = image
        } else {
            button.image = nil
            button.title = "✧"
        }
        button.imagePosition = .imageLeading

        var showSize = cfg.showSizeInMenuBar
        let cleanable = scan?.cleanableBytes ?? 0
        if cfg.notifyAboveGB > 0,
           Double(cleanable) > cfg.notifyAboveGB * 1024 * 1024 * 1024 {
            showSize = true
        }
        if showSize && cleanable > 0 {
            button.title = " " + humanShort(cleanable)
        } else {
            button.title = ""
        }
        button.toolTip = busyMessage.map { $0 + "…" } ?? tooltip()
        button.setAccessibilityLabel("JustCleaner")
        button.setAccessibilityHelp(button.toolTip)
    }

    private func tooltip() -> String {
        guard let s = scan else { return "JustCleaner - not checked yet" }
        var t = "JustCleaner: \(human(s.cleanableBytes)) of junk (checked \(s.ageDescription))"
        if s.blockedBytes > 0 {
            t += "\nReady to clean: \(human(s.readyBytes)); retained items free space after expiry"
            if let sentence = s.blockedSentence { t += " - " + sentence }
        }
        if let d = s.disk { t += "\n\(human(d.free)) free of \(human(d.total))" }
        return t
    }

    // MARK: - scanning

    private func tick() {
        guard cfg.autoScanHours > 0, busyMessage == nil else { return }
        let last = scan?.finishedAt ?? 0
        if nowTS() - last > cfg.autoScanHours * 3600 {
            refresh(deep: false)
        }
    }

    private func work(_ message: String, _ block: @escaping () -> Void) {
        guard operationID == nil else { return }
        let id = UUID()
        operationID = id
        busyMessage = message
        busyStartedAt = nowTS()
        progressDetail = "You can keep using your Mac."
        progressTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.retitleLiveItems()
        }
        RunLoop.main.add(progressTimer!, forMode: .common)
        redrawIcon()
        rebuild()
        DispatchQueue.global(qos: .utility).async {
            block()
            let batches = Quarantine.batches(measure: false)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operationID == id else { return }
                self.batches = batches
                self.loadedBatches = true
                self.finishWork()
            }
        }
    }

    private func finishWork() {
        operationID = nil
        busyMessage = nil
        restoreActions(in: menu)
        progressTimer?.invalidate()
        progressTimer = nil
        redrawIcon()
        rebuild()
    }

    private func showProgress(_ detail: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.operationID != nil else { return }
            self.progressDetail = detail
            self.retitleLiveItems()
        }
    }

    private func loadBatches() {
        let requestedDuring = operationID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let batches = Quarantine.batches(measure: false)
            DispatchQueue.main.async {
                guard let self, self.operationID == requestedDuring else { return }
                self.batches = batches
                self.loadedBatches = true
                self.rebuild()
            }
        }
    }

    private func refresh(deep: Bool) {
        guard busyMessage == nil else { return }
        let cfg = self.cfg
        work(deep ? "Scanning projects and caches" : "Scanning caches") { [weak self] in
            guard let self else { return }
            _ = Cleaner.expireOldBatches(cfg)     // quiet housekeeping
            let result = JunkScanner.scan(deep: deep, cfg: cfg, progress: { self.showProgress($0) })
            DispatchQueue.main.async { self.scan = result; self.cfg = Config.load() }
        }
    }

    // MARK: - menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Draw immediately from what is already known - a menu that thinks is a
        // menu that feels broken. Which apps are open is then re-checked off the
        // main thread, and the headline corrects itself in place a moment later.
        cfg = Config.load()
        rebuild()
        refreshBlockedInfo()
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if needsRebuild { rebuild() }
    }

    private func refreshBlockedInfo() {
        guard let snapshot = scan, busyMessage == nil, !snapshot.categories.isEmpty,
              !updatingProcesses else { return }
        updatingProcesses = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let processes = Cleaner.runningProcessNames(maxAge: 4)
            let preview = Cleaner.plan(snapshot, respectRunningApps: true, processes: processes)
            let blockedBytes = preview.blockedBytes
            let blockedApps = preview.blockedByApp.map { $0.app }
            DispatchQueue.main.async {
                guard let self else { return }
                self.updatingProcesses = false
                guard self.busyMessage == nil, var current = self.scan,
                      current.finishedAt == snapshot.finishedAt else { return }
                let same = current.blockedBytes == blockedBytes
                    && current.blockedApps == blockedApps
                    && self.runningProcesses == processes
                self.runningProcesses = processes
                guard !same else { return }
                current.blockedBytes = blockedBytes
                current.blockedApps = blockedApps
                self.scan = current
                self.redrawIcon()
                if self.menuIsOpen { self.retitleLiveItems() } else { self.rebuild() }
            }
        }
    }

    /// Correct the few lines that depend on which apps are open, without
    /// disturbing the menu the pointer is currently in.
    private func retitleLiveItems() {
        if let message = busyMessage {
            let elapsed = max(0, Int(nowTS() - busyStartedAt))
            headlineItem?.title = message + "…"
            headlineItem?.attributedTitle = emphasised(message + "…")
            let detail = "\(elapsed)s · " + compact(progressDetail, limit: 62)
            sublineItem?.title = detail
            sublineItem?.attributedTitle = quiet(detail)
            sublineItem?.toolTip = progressDetail
            blockedItem?.isHidden = true
        } else if let s = scan {
            let headline = s.cleanableBytes > 0 ? "Cleanup estimate: " + human(s.cleanableBytes) : "No cleanup found"
            headlineItem?.title = headline
            headlineItem?.attributedTitle = emphasised(headline)
            sublineItem?.title = subline(s)
            sublineItem?.attributedTitle = quiet(subline(s))
            blockedItem?.title = s.blockedSentence ?? ""
            blockedItem?.attributedTitle = quiet(s.blockedSentence ?? "")
            blockedItem?.isHidden = s.blockedSentence == nil
        }
        if let clean = cleanItem {
            let label = MenuPresentation.cleanTitle(scan, busy: busyMessage != nil)
            clean.title = label
            clean.attributedTitle = emphasised(label)
            clean.isEnabled = busyMessage == nil && Config.loadIssue == nil && (scan?.readyBytes ?? 0) > 0
        }
        if busyMessage != nil { disableActions(in: menu) }
    }

    private func disableActions(in menu: NSMenu) {
        for item in menu.items {
            if item.action != nil {
                let key = ObjectIdentifier(item)
                if disabledStates[key] == nil { disabledStates[key] = item.isEnabled }
                item.isEnabled = false
            }
            if let sub = item.submenu { disableActions(in: sub) }
        }
    }

    private func restoreActions(in menu: NSMenu) {
        for item in menu.items {
            if let enabled = disabledStates.removeValue(forKey: ObjectIdentifier(item)) { item.isEnabled = enabled }
            if let sub = item.submenu { restoreActions(in: sub) }
        }
    }

    private func compact(_ text: String, limit: Int = 64) -> String {
        MenuPresentation.compact(text, limit: limit)
    }

    private func add(_ title: String, _ selector: Selector? = nil,
                     key: String = "", enabled: Bool = true,
                     state: NSControl.StateValue? = nil,
                     indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = selector == nil ? nil : self
        item.isEnabled = enabled && selector != nil
        item.indentationLevel = indent
        if let state { item.state = state }
        menu.addItem(item)
        return item
    }

    /// A row that carries a submenu: never dimmed, never clickable itself.
    private func addBranch(_ title: String, indent: Int = 0, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.indentationLevel = indent
        item.submenu = submenu
        menu.addItem(item)
        return item
    }

    /// A category row: name on the left, size set quietly behind it.
    @discardableResult
    private func addRow(_ name: String, _ size: Int64, indent: Int = 1,
                        _ submenu: NSMenu) -> NSMenuItem {
        let item = addBranch(name, indent: indent, submenu)
        item.attributedTitle = twoTone(name, human(size))
        return item
    }

    @discardableResult
    private func addInfo(_ title: String, indent: Int = 0, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indent
        if bold { item.attributedTitle = emphasised(title) }
        menu.addItem(item)
        return item
    }

    /// A quiet, letter-spaced heading. Uppercase because the eye reads it as a
    /// label rather than a line to click.
    @discardableResult
    private func addSection(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .kern: 1.1])
        menu.addItem(item)
        return item
    }

    private func emphasised(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text,
                           attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
    }

    private func quiet(_ text: String, size: CGFloat = 11) -> NSAttributedString {
        NSAttributedString(string: text,
                           attributes: [.font: NSFont.systemFont(ofSize: size),
                                        .foregroundColor: NSColor.secondaryLabelColor])
    }

    /// "Homebrew's old versions   412 MB" — one line, two weights.
    private func twoTone(_ lead: String, _ trail: String) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: lead,
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor])
        out.append(NSAttributedString(
            string: "   " + trail,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        return out
    }

    private func subline(_ s: ScanResult) -> String {
        var sub = "checked " + s.ageDescription
        if let d = s.disk { sub += " · \(human(d.free)) free of \(human(d.total))" }
        sub += s.isDeep ? " · deep scan" : " · cache scan"
        return sub
    }

    private func rebuild() {
        if menuIsOpen {
            needsRebuild = true
            retitleLiveItems()
            return
        }
        needsRebuild = false
        disabledStates.removeAll()
        menu.removeAllItems()
        let s = scan
        let settingsIssue = Config.loadIssue

        // ---- headline ----
        if let message = busyMessage {
            headlineItem = addInfo(message + "…", bold: true)
            sublineItem = addInfo(progressDetail, indent: 1)
            blockedItem = nil
        } else if let s {
            headlineItem = addInfo(s.cleanableBytes > 0 ? "Cleanup estimate: " + human(s.cleanableBytes) : "No cleanup found", bold: true)
            let sub = addInfo(subline(s), indent: 1)
            sub.attributedTitle = quiet(subline(s))
            sublineItem = sub
            let blocked = addInfo("", indent: 1)
            if let sentence = s.blockedSentence {
                blocked.attributedTitle = quiet(sentence)
            } else {
                blocked.isHidden = true
            }
            blockedItem = blocked
        } else {
            headlineItem = addInfo("Ready to scan", bold: true)
            let sub = addInfo("Scan to find caches you can remove.",
                              indent: 1)
            sub.attributedTitle = quiet(sub.title)
            sublineItem = sub
            blockedItem = nil
        }
        if let s, !s.warnings.isEmpty {
            let warning = add("Scan notes (\(s.warnings.count)) — open report…", #selector(openReport))
            warning.toolTip = s.warnings.joined(separator: "\n")
        }
        if let issue = settingsIssue {
            let warning = addInfo("Settings need attention — cleanup paused", indent: 1)
            warning.toolTip = issue
        }
        // Feedback from the last action, kept only while it is still news.
        if let line = lastResultLine, nowTS() - lastResultAt < 900 {
            addInfo(line, indent: 1).attributedTitle = quiet(line)
        }

        menu.addItem(.separator())

        // ---- the one button that matters ----
        let cleanLabel = MenuPresentation.cleanTitle(s, busy: busyMessage != nil)
        let clean = add(cleanLabel, #selector(cleanNow), key: "k",
                        enabled: (s?.readyBytes ?? 0) > 0)
        clean.attributedTitle = emphasised(cleanLabel)
        cleanItem = clean
        if let s, s.readyBytes > 0 {
            let note = cfg.freeSafeItemsImmediately
                ? "Disposable caches are deleted; other files remain recoverable."
                : "Files remain recoverable until the retention period ends."
            addInfo(note, indent: 1).attributedTitle = quiet(note)
        }
        _ = add(s == nil ? "Scan now" : "Scan again", #selector(rescan), key: "r")
        if s == nil {
            addInfo("Music and personal files are protected.", indent: 1)
        }

        // ---- what is in there ----
        if let s {
            let cleanables = s.categories.filter { $0.risk == .safe || $0.risk == .slower }
            if !cleanables.isEmpty || s.homebrewFreeableBytes > 0 {
                menu.addItem(.separator())
                addSection("Cleanup details")
                for cat in cleanables {
                    addRow(MenuPresentation.categoryTitle(cat), cat.bytes, categorySubmenu(cat))
                }
                if s.homebrewFreeableBytes > 0 {
                    addRow("Homebrew's old versions", s.homebrewFreeableBytes, homebrewSubmenu(s))
                }
            }

            // ---- your call ----
            menu.addItem(.separator())
            let decisions = s.categories.filter { $0.risk == .review }
            let onlyInfo = s.categories.filter { $0.risk == .info }
            if !decisions.isEmpty {
                addSection("Review before removing  ·  " + human(s.decisionBytes))
                for cat in decisions {
                    addRow(MenuPresentation.categoryTitle(cat), cat.bytes, reviewSubmenu(cat))
                }
            }
            let deep = add(s.isDeep ? "Run deep scan again" : "Run deep scan…",
                           #selector(deepScan), enabled: busyMessage == nil)
            deep.toolTip = "Include projects, AI models, chat history, and Trash."
            if !onlyInfo.isEmpty {
                addSection("Where the disk went")
                for cat in onlyInfo {
                    addRow(MenuPresentation.categoryTitle(cat), cat.bytes, reviewSubmenu(cat))
                }
            }
        }

        // ---- safety net ----
        menu.addItem(.separator())
        let netBytes = batches.reduce(Int64(0)) { $0 + $1.bytes }
        _ = addBranch(!loadedBatches ? "Safety net: checking…" : (batches.isEmpty ? "Safety net: empty" : "Safety net: \(human(netBytes)) retained"),
                      safetyNetSubmenu(netBytes))

        _ = add("Open full report…", #selector(openReport), key: "o")

        // ---- settings ----
        menu.addItem(.separator())
        _ = addBranch("Settings", settingsSubmenu())
        _ = addBranch("More", moreSubmenu())
        _ = add("Quit JustCleaner", #selector(quit), key: "q")
        applyAppearance(NSApp.effectiveAppearance, to: menu)
        if busyMessage != nil { disableActions(in: menu) }
        else if settingsIssue != nil { disableCleanup(in: menu) }
    }

    private func moreSubmenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let actions: [(String, Selector)] = [
            ("Export app for another Mac…", #selector(packForAnotherMac)),
            ("Open activity log…", #selector(openLog)),
            ("About JustCleaner", #selector(about))
        ]
        for (title, action) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            sub.addItem(item)
        }
        return sub
    }

    private func disableCleanup(in menu: NSMenu) {
        let destructive: Set<String> = ["cleanNow", "cleanCategory:", "runHomebrewOnly", "emptyTrash", "purgeAll"]
        for item in menu.items {
            if let action = item.action, destructive.contains(NSStringFromSelector(action)) { item.isEnabled = false }
            if let sub = item.submenu { disableCleanup(in: sub) }
        }
    }

    // MARK: - submenus

    private func explainItem(_ text: String, into sub: NSMenu, width: Int = 62) {
        for line in wrap(text, width: width) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: line,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor])
            sub.addItem(item)
        }
    }

    private func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.count + word.count + 1 > width {
                if !current.isEmpty { lines.append(current) }
                current = String(word)
            } else {
                current += (current.isEmpty ? "" : " ") + word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private func pathItems(_ cat: CategoryResult, into sub: NSMenu, limit: Int = 10) {
        for item in cat.items.prefix(limit) {
            let fullPath = tildePath(item.path)
            let path = compact(fullPath)
            var trail = (item.partial ? "at least " : "") + human(item.bytes)
            var tip = fullPath + "\n" + item.note
            if cat.kind != .info,
               let app = Cleaner.blockingApp(cat.id, processes: runningProcesses)
                ?? Cleaner.blockingOwner(item.path, processes: runningProcesses) {
                trail += "  ·  in use"
                tip += "\n\(app) is open right now, so this one is left alone"
            }
            let entry = NSMenuItem(title: path + "   " + trail,
                                   action: #selector(revealPath(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.path
            entry.toolTip = tip + "\nClick to show it in Finder"
            let line = NSMutableAttributedString(
                string: path,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                             .foregroundColor: NSColor.labelColor])
            line.append(NSAttributedString(
                string: "   " + trail,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor]))
            entry.attributedTitle = line
            sub.addItem(entry)
        }
        if cat.items.count > limit {
            let more = NSMenuItem(title: "See all \(cat.items.count) folders in the report…",
                                  action: #selector(openReport), keyEquivalent: "")
            more.target = self
            sub.addItem(more)
        }
    }

    private func categorySubmenu(_ cat: CategoryResult) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        explainItem(cat.what, into: sub)
        sub.addItem(.separator())
        let risk = NSMenuItem(title: cat.risk.label, action: nil, keyEquivalent: "")
        risk.isEnabled = false
        risk.attributedTitle = quiet(cat.risk.label, size: 11)
        sub.addItem(risk)
        sub.addItem(.separator())
        pathItems(cat, into: sub)
        sub.addItem(.separator())
        let ready = cat.items.filter {
            Cleaner.blockingApp(cat.id, processes: runningProcesses) == nil
                && Cleaner.blockingOwner($0.path, processes: runningProcesses) == nil
        }.reduce(Int64(0)) { $0 + $1.bytes }
        let clean = NSMenuItem(title: ready > 0 ? "Clean this category  ·  \(human(ready))" : "In use — close the app first",
                               action: #selector(cleanCategory(_:)), keyEquivalent: "")
        clean.target = self
        clean.representedObject = cat.id
        clean.isEnabled = ready > 0
        sub.addItem(clean)
        return sub
    }

    private func reviewSubmenu(_ cat: CategoryResult) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        explainItem(cat.what, into: sub)
        sub.addItem(.separator())
        pathItems(cat, into: sub)
        sub.addItem(.separator())
        if cat.id == "trash" {
            let empty = NSMenuItem(title: "Empty Trash…  ·  \(human(cat.bytes))",
                                   action: #selector(emptyTrash), keyEquivalent: "")
            empty.target = self
            sub.addItem(empty)
            explainItem("Emptying the Trash cannot be undone, so JustCleaner never does it "
                        + "for you automatically.", into: sub)
        } else if cat.kind == .info {
            let note = NSMenuItem(title: "JustCleaner never touches these", action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(note)
        } else {
            let clean = NSMenuItem(
                title: "Move to safety net…  ·  \(human(cat.bytes))",
                action: #selector(cleanCategory(_:)), keyEquivalent: "")
            clean.target = self
            clean.representedObject = cat.id
            sub.addItem(clean)
            explainItem("Retained for \(Int(cfg.keepDays)) days. Restoring may require closing the app and moving any replacement folder first.", into: sub)
        }
        return sub
    }

    private func homebrewSubmenu(_ s: ScanResult) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        explainItem("Remove old versions and downloads using Homebrew’s cleanup command. This bypasses the safety net and cannot be undone here.", into: sub)
        sub.addItem(.separator())
        let run = NSMenuItem(title: "Run Homebrew cleanup  ·  \(human(s.homebrewFreeableBytes))",
                             action: #selector(runHomebrewOnly), keyEquivalent: "")
        run.target = self
        sub.addItem(run)
        return sub
    }

    private func safetyNetSubmenu(_ bytes: Int64) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        explainItem("Select a batch to restore. Retained files normally expire after \(Int(cfg.keepDays)) days. Incomplete or failed batches remain for inspection.", into: sub)
        sub.addItem(.separator())
        let older = NSMenu()
        older.autoenablesItems = false
        for (index, b) in batches.enumerated() {
            let label = "\(humanDate(b.createdAt))   \(human(b.bytes))"
            let item = NSMenuItem(title: label, action: #selector(restoreBatch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = b.path
            item.isEnabled = b.isRestorable
            item.toolTip = b.isRestorable ? "Restore this cleanup" : "No recovery entries; inspect this batch in Finder."
            (index < 8 ? sub : older).addItem(item)
        }
        if !older.items.isEmpty {
            let more = NSMenuItem(title: "Older cleanups (\(older.items.count))", action: nil, keyEquivalent: "")
            more.submenu = older
            sub.addItem(more)
        }
        if batches.isEmpty {
            let item = NSMenuItem(title: "Nothing waiting", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = quiet("Nothing waiting")
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let undo = NSMenuItem(title: "Restore latest cleanup",
                              action: #selector(undoLast), keyEquivalent: "")
        undo.target = self
        undo.isEnabled = batches.contains { $0.isRestorable }
        sub.addItem(undo)
        let purge = NSMenuItem(title: bytes > 0
                               ? "Empty safety net…  ·  \(human(bytes))"
                               : "Empty safety net…",
                               action: #selector(purgeAll), keyEquivalent: "")
        purge.target = self
        purge.isEnabled = !batches.isEmpty
        sub.addItem(purge)
        let open = NSMenuItem(title: "Show the safety net in Finder",
                              action: #selector(openQuarantine), keyEquivalent: "")
        open.target = self
        sub.addItem(open)
        return sub
    }

    private func settingsSubmenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        func toggle(_ title: String, _ on: Bool, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            sub.addItem(item)
        }

        toggle("Start at login", LoginItem.isEnabled, #selector(toggleLogin))
        toggle("Show size in menu bar", cfg.showSizeInMenuBar, #selector(toggleShowSize))
        toggle("Show cleanup summary", cfg.showSummaryAfterClean, #selector(toggleSummary))

        sub.addItem(.separator())
        let freq = NSMenuItem(title: "Scan automatically", action: nil, keyEquivalent: "")
        let freqMenu = NSMenu()
        freqMenu.autoenablesItems = false
        for (label, hours) in [("Never", 0.0), ("Every hour", 1), ("Every 6 hours", 6),
                               ("Once a day", 24)] {
            let item = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hours
            item.state = cfg.autoScanHours == hours ? .on : .off
            freqMenu.addItem(item)
        }
        freq.submenu = freqMenu
        sub.addItem(freq)

        let keep = NSMenuItem(title: "Keep recoverable files for", action: nil, keyEquivalent: "")
        let keepMenu = NSMenu()
        keepMenu.autoenablesItems = false
        for (label, days) in [("1 day", 1.0), ("3 days", 3), ("1 week", 7), ("2 weeks", 14)] {
            let item = NSMenuItem(title: label, action: #selector(setKeepDays(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = days
            item.state = cfg.keepDays == days ? .on : .off
            keepMenu.addItem(item)
        }
        keep.submenu = keepMenu
        sub.addItem(keep)

        sub.addItem(.separator())
        toggle("Delete disposable caches immediately", cfg.freeSafeItemsImmediately,
               #selector(toggleImmediate))
        toggle("Include browser caches", cfg.includeBrowserCaches, #selector(toggleBrowsers))
        toggle("Include Homebrew cleanup", cfg.includeHomebrewCleanup,
               #selector(toggleHomebrew))
        toggle("Scan coding projects", cfg.scanProjects, #selector(toggleProjects))
        toggle("Include Desktop, Documents, Downloads", cfg.scanPersonalFolders,
               #selector(togglePersonal))

        sub.addItem(.separator())
        let fda = NSMenuItem(title: "Give JustCleaner Full Disk Access…",
                             action: #selector(openFullDiskAccess), keyEquivalent: "")
        fda.target = self
        fda.toolTip = "Optional. Allows measurement of folders macOS restricts; protected files still cannot be cleaned."
        sub.addItem(fda)
        let file = NSMenuItem(title: "Open the settings file",
                              action: #selector(openConfig), keyEquivalent: "")
        file.target = self
        sub.addItem(file)
        let reset = NSMenuItem(title: "Reset settings…", action: #selector(resetSettings), keyEquivalent: "")
        reset.target = self
        sub.addItem(reset)
        return sub
    }

    // MARK: - actions

    @objc private func rescan() { refresh(deep: false) }

    @objc private func deepScan() {
        // an explicit "look again" must really look again
        ProjectScanner.invalidate()
        refresh(deep: true)
    }

    @objc private func cleanNow() {
        guard let s = scan else { return }
        let cfg = self.cfg
        work("Cleaning up") { [weak self] in
            // ask again which apps are open: the answer decides what may move,
            // and a menu can sit open for a while before the click arrives
            let plan = Cleaner.plan(s, processes: Cleaner.runningProcessNames())
            let outcome = Cleaner.apply(plan.items, cfg: cfg,
                                        runHomebrew: cfg.includeHomebrewCleanup,
                                        progress: { self?.showProgress($0) })
            // keep whatever depth the user was looking at
            self?.showProgress("Refreshing the results")
            let fresh = JunkScanner.scan(deep: s.isDeep, cfg: cfg)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cfg = Config.load()
                self.scan = fresh
                self.lastResultLine = self.resultLine(outcome)
                self.finishWork()
                self.loadBatches()
                if self.cfg.showSummaryAfterClean {
                    self.showSummary(outcome, skipped: plan.skipped + outcome.skippedBecauseRunning.map { "\($0) started running; its files were left alone" })
                }
            }
        }
    }

    @objc private func cleanCategory(_ sender: NSMenuItem) {
        guard busyMessage == nil, let id = sender.representedObject as? String, let s = scan else { return }
        let cfg = self.cfg
        if s.category(id)?.risk == .review {
            let question = NSAlert()
            question.messageText = "Move these files to the safety net?"
            question.informativeText = (s.category(id)?.what ?? "") + "\n\nRetained for \(Int(cfg.keepDays)) days. The app or project may need these files again."
            question.addButton(withTitle: "Cancel")
            question.addButton(withTitle: "Move to Safety Net")
            NSApp.activate(ignoringOtherApps: true)
            guard question.runModal() == .alertSecondButtonReturn else { return }
        }
        work("Cleaning") { [weak self] in
            let plan = Cleaner.plan(s, includeIDs: [id],
                                    processes: Cleaner.runningProcessNames())
            let outcome = Cleaner.apply(plan.items, cfg: cfg, progress: { self?.showProgress($0) })
            self?.showProgress("Refreshing the results")
            let fresh = JunkScanner.scan(deep: s.isDeep, cfg: cfg)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cfg = Config.load()
                self.scan = fresh
                self.lastResultLine = self.resultLine(outcome)
                self.finishWork()
                self.loadBatches()
                if self.cfg.showSummaryAfterClean {
                    self.showSummary(outcome, skipped: plan.skipped + outcome.skippedBecauseRunning.map { "\($0) started running; its files were left alone" })
                }
            }
        }
    }

    @objc private func runHomebrewOnly() {
        let cfg = self.cfg
        let deep = scan?.isDeep ?? false
        work("Waiting for Homebrew") { [weak self] in
            guard let operation = DiskOperation() else {
                DispatchQueue.main.async { self?.lastResultLine = "Another cleanup is running. Try again when it finishes." }
                return
            }
            let result = Homebrew.cleanup()
            let before = Homebrew.parseSize(result.output)
            if result.ok, before > 0 {
                if !Config.recordFreed(before, cleaned: true) { appLog("Could not save Homebrew statistics") }
            }
            operation.finish()
            let fresh = JunkScanner.scan(deep: deep, cfg: cfg)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cfg = Config.load()
                self.scan = fresh
                self.lastResultLine = result.ok
                    ? (before > 0 ? "Homebrew removed an estimated \(human(before))" : "Homebrew cleanup completed")
                    : "Homebrew could not be run"
            }
        }
    }

    @objc private func emptyTrash() {
        guard busyMessage == nil else { return }
        let question = NSAlert()
        question.messageText = "Empty the Trash?"
        question.informativeText = "This cannot be undone. "
            + "Everything in the Trash will be gone for good."
        question.addButton(withTitle: "Cancel")
        question.addButton(withTitle: "Empty Trash")
        question.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard question.runModal() == .alertSecondButtonReturn else { return }
        let cfg = self.cfg
        let deep = scan?.isDeep ?? false
        work("Emptying the Trash") { [weak self] in
            let result = Cleaner.emptyTrash()
            let fresh = JunkScanner.scan(deep: deep, cfg: cfg)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cfg = Config.load()
                self.scan = fresh
                self.lastResultLine = result.summary
            }
        }
    }

    @objc private func undoLast() {
        guard let batch = batches.first(where: { $0.isRestorable }) else { return }
        restore(batch)
    }

    @objc private func restoreBatch(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let batch = batches.first(where: { $0.path == path }) else { return }
        restore(batch)
    }

    private func restore(_ batch: Batch) {
        let cfg = self.cfg
        let deep = scan?.isDeep ?? false
        work("Putting everything back") { [weak self] in
            let r = Quarantine.restore(batch)
            let fresh = JunkScanner.scan(deep: deep, cfg: cfg)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cfg = Config.load()
                self.scan = fresh
                self.lastResultLine = "Restored \(r.restored) place(s)"
                    + (r.failed > 0 ? "; \(r.failed) need attention" : "")
                if r.failed > 0 {
                    self.finishWork()
                    self.loadBatches()
                    let alert = NSAlert()
                    alert.messageText = "Some files could not be restored"
                    alert.informativeText = "JustCleaner leaves existing files in place. Close the app that uses these files, then use Finder to inspect the original location and this safety-net batch. Move any replacement folder somewhere safe before retrying. Do not delete files you want to keep."
                    alert.addButton(withTitle: "Show Retained Files")
                    alert.addButton(withTitle: "Close")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        self.openFile(batch.path)
                    }
                }
            }
        }
    }

    @objc private func purgeAll() {
        guard busyMessage == nil else { return }
        let question = NSAlert()
        question.messageText = "Permanently empty the safety net?"
        question.informativeText = "Retained files from \(batches.count) cleanup(s) will be deleted. You will no longer be able to undo those cleanups."
        question.alertStyle = .warning
        question.addButton(withTitle: "Cancel")
        question.addButton(withTitle: "Empty Safety Net")
        NSApp.activate(ignoringOtherApps: true)
        guard question.runModal() == .alertSecondButtonReturn else { return }
        let cfg = self.cfg
        let deep = scan?.isDeep ?? false
        work("Releasing the space") { [weak self] in
            let result = Quarantine.purgeAll()
            let fresh = JunkScanner.scan(deep: deep, cfg: cfg)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cfg = Config.load()
                self.scan = fresh
                self.lastResultLine = result.summary
            }
        }
    }

    /// Writing the report walks the safety net, so it never happens on the main
    /// thread: the menu bar must not freeze because somebody was curious. A
    /// report from a quick look would be missing half its subject, so if only a
    /// quick look exists, a deep one is taken first.
    @objc private func openReport() {
        let cfg = self.cfg
        let known = scan
        work("Writing the report") { [weak self] in
            let s = known.flatMap { $0.isDeep && nowTS() - $0.finishedAt < 1800 ? $0 : nil }
                ?? JunkScanner.scan(deep: true, cfg: cfg)
            do {
                let path = try Report.write(s, cfg: cfg)
                DispatchQueue.main.async {
                    self?.scan = s
                    if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
                        self?.lastResultLine = "Report saved, but could not open it: " + path
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.lastResultLine = "Could not save report: " + error.localizedDescription }
            }
        }
    }

    private func openFile(_ path: String) {
        guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
            lastResultLine = "Could not open " + compact(tildePath(path))
            rebuild()
            return
        }
    }

    @objc private func openQuarantine() {
        Paths.ensureStateDirs()
        openFile(Paths.quarantineDir)
    }

    @objc private func openLog() {
        openFile(Paths.logFile)
    }

    @objc private func openConfig() {
        openFile(Paths.configFile)
    }

    @objc private func openFullDiskAccess() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
        let note = NSAlert()
        note.messageText = "Add JustCleaner to the list"
        note.informativeText = "System Settings is opening at Privacy & Security > Full Disk "
            + "Access. Press the + button and choose JustCleaner from your Applications folder.\n\n"
            + "This is optional. It lets JustCleaner measure more folders. Music, Mail and other protected data remain excluded from cleanup."
        note.addButton(withTitle: "Got it")
        NSApp.activate(ignoringOtherApps: true)
        note.runModal()
    }

    @objc private func revealPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        if !NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath:
            (path as NSString).deletingLastPathComponent) {
            lastResultLine = "This folder is no longer available. Scan again to refresh."
            rebuild()
        }
    }

    @objc private func packForAnotherMac() {
        work("Packing JustCleaner up…") { [weak self] in
            let result = SharePackager.pack()
            DispatchQueue.main.async {
                guard let self else { return }
                self.finishWork()
                switch result {
                case .success(let zipPath):
                    self.lastResultLine = "Ready on your Desktop"
                    NSWorkspace.shared.selectFile(zipPath, inFileViewerRootedAtPath:
                        (zipPath as NSString).deletingLastPathComponent)
                    let note = NSAlert()
                    note.messageText = "JustCleaner is packed and ready"
                    note.informativeText = """
                        \(tildePath(zipPath))

                        Send that file to your other Mac however you like - AirDrop, a USB \
                        stick, a cloud folder. On the other Mac: unzip it, then double-click \
                        "Install JustCleaner.command" inside. If macOS asks, right-click the file \
                        and choose Open.

                        Nothing else is needed there: no developer tools, no downloads, no \
                        settings. It will find that Mac's own junk by itself.
                        """
                    note.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    note.runModal()
                case .failure(let message):
                    self.lastResultLine = "Could not pack: " + message
                }
            }
        }
    }

    @objc private func about() {
        let a = NSAlert()
        a.messageText = "JustCleaner \(JustCleanerVersion.string)"
        var text = """
            A quiet menu bar tool that finds throwaway files left behind by coding tools, \
            browsers and apps, explains them in plain language, and removes them with one \
            click. Music, projects, documents and settings are protected by rules that \
            cannot be switched off.

            """
        if cfg.totalFreedBytes > 0 {
            text += "\nEstimated space released on this Mac: \(human(cfg.totalFreedBytes))."
        }
        if cfg.lastCleanAt > 0 {
            text += "\nLast cleanup: \(humanDate(cfg.lastCleanAt))."
        }
        text += "\n\nSettings: ~/.justcleaner/config.json\nLog: ~/.justcleaner/justcleaner.log"
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Show the report")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { openReport() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - settings actions

    @objc private func toggleLogin() {
        let enabled = LoginItem.isEnabled
        work("Updating start at login") { [weak self] in
            let success = enabled ? LoginItem.disable() : LoginItem.enable()
            DispatchQueue.main.async {
                self?.lastResultLine = success
                    ? (enabled ? "Start at login disabled" : "Start at login enabled")
                    : "Could not change start at login. Check folder permissions and retry."
            }
        }
    }

    private func saveSetting<T>(_ key: WritableKeyPath<Config, T>, _ value: T,
                                rescan: Bool = false, deep: Bool = false) {
        work("Saving settings") { [weak self] in
            let saved = Config.update { $0[keyPath: key] = value }
            let current = Config.load()
            var refreshed: ScanResult?
            if saved && rescan {
                ProjectScanner.invalidate()
                refreshed = JunkScanner.scan(deep: deep, cfg: current)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cfg = current
                if let refreshed { self.scan = refreshed }
                if !saved { self.lastResultLine = "Could not save settings. Repair or reset them in Settings." }
            }
        }
    }

    @objc private func resetSettings() {
        guard busyMessage == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Reset settings?"
        alert.informativeText = "Your current settings file will be kept as a backup. Recovery files and reports will stay in place. Defaults allow safe-cache deletion after you choose Clean up."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset Settings")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        work("Resetting settings") { [weak self] in
            do {
                _ = try Config.reset()
                DispatchQueue.main.async {
                    self?.cfg = Config.load()
                    self?.lastResultLine = "Settings reset; previous file backed up"
                }
            } catch {
                DispatchQueue.main.async { self?.lastResultLine = "Could not reset settings: " + error.localizedDescription }
            }
        }
    }

    @objc private func toggleShowSize() { saveSetting(\.showSizeInMenuBar, !cfg.showSizeInMenuBar) }
    @objc private func toggleSummary() { saveSetting(\.showSummaryAfterClean, !cfg.showSummaryAfterClean) }
    @objc private func toggleImmediate() { saveSetting(\.freeSafeItemsImmediately, !cfg.freeSafeItemsImmediately) }
    @objc private func toggleBrowsers() { saveSetting(\.includeBrowserCaches, !cfg.includeBrowserCaches, rescan: true) }
    @objc private func toggleHomebrew() { saveSetting(\.includeHomebrewCleanup, !cfg.includeHomebrewCleanup, rescan: true) }
    @objc private func toggleProjects() { saveSetting(\.scanProjects, !cfg.scanProjects, rescan: true, deep: !cfg.scanProjects) }
    @objc private func togglePersonal() { saveSetting(\.scanPersonalFolders, !cfg.scanPersonalFolders, rescan: true, deep: scan?.isDeep ?? false) }

    @objc private func setInterval(_ sender: NSMenuItem) {
        saveSetting(\.autoScanHours, (sender.representedObject as? Double) ?? 6)
    }

    @objc private func setKeepDays(_ sender: NSMenuItem) {
        saveSetting(\.keepDays, (sender.representedObject as? Double) ?? 3)
    }

    // MARK: - feedback

    private func resultLine(_ o: CleanOutcome) -> String {
        if o.failedCount > 0 && o.itemCount == 0 { return "Cleanup could not finish" }
        if o.itemCount == 0 && o.brewFreedBytes == 0 { return "No files removed" }
        var line = "Cleaned \(human(o.movedBytes + o.brewFreedBytes))"
        if o.parkedBytes > 0 { line += ", \(human(o.parkedBytes)) recoverable" }
        if o.failedCount > 0 { line += "; \(o.failedCount) failed — see the log" }
        return line
    }

    private func showSummary(_ o: CleanOutcome, skipped: [String]) {
        let a = NSAlert()
        if o.failedCount > 0 && o.itemCount == 0 {
            a.messageText = "Cleanup could not finish"
            a.informativeText = "\(o.failedCount) operation(s) failed or were refused. Some files may already have moved or been removed. Check the activity log and safety net before retrying."
        } else if o.itemCount == 0 && o.brewFreedBytes == 0 {
            a.messageText = "No files removed"
            a.informativeText = skipped.isEmpty
                ? "No eligible files were available. Scan again to refresh the results."
                : "Skipped for now:\n• " + skipped.joined(separator: "\n• ")
        } else {
            a.messageText = "Cleaned \(human(o.movedBytes + o.brewFreedBytes))"
            var text = ""
            if o.freedNowBytes > 0 {
                text += "Removed an estimated \(human(o.freedNowBytes)) from the safety net. APFS snapshots, shared blocks, or open files may delay space becoming available.\n"
            }
            if o.parkedBytes > 0 {
                text += "\(human(o.parkedBytes)) is in the safety net and can be put back for "
                    + "\(Int(cfg.keepDays)) more day(s), then the space is released "
                    + "after a later scan. Failed batches stay for inspection.\n"
            }
            text += "\(o.itemCount) place(s) tidied."
            if o.failedCount > 0 { text += "  \(o.failedCount) operation(s) need attention." }
            if !skipped.isEmpty {
                text += "\n\nLeft alone because an app is using it:\n• "
                    + skipped.joined(separator: "\n• ")
            }
            a.informativeText = text
        }
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Show the report")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { openReport() }
    }
}
