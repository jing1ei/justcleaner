import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no dock icon, no window
        Paths.ensureStateDirs()

        // refuse to run twice: a second icon in the menu bar is just confusing
        let mine = getpid()
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: JustCleanerVersion.bundleID)
            .filter { $0.processIdentifier != mine }
        if !others.isEmpty {
            appLog("another copy is already running, quitting this one")
            NSApp.terminate(nil)
            return
        }

        controller = MenuController()
        appLog("started \(JustCleanerVersion.string) from " + (Bundle.main.bundlePath))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
