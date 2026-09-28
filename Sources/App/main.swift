import AppKit

// One binary, two personalities:
//   JustCleaner            -> the silent menu bar app
//   JustCleaner scan|clean -> the same engine, in Terminal

let arguments = Array(CommandLine.arguments.dropFirst())

if let first = arguments.first, first != "--menubar" {
    exit(CLI.run(arguments))
}

let app = NSApplication.shared
app.appearance = nil // Inherit macOS Light, Dark, or Auto.
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
