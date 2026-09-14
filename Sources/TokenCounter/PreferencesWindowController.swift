import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    func show(store: MonitorStore) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: PreferencesView(store: store))
        // The SwiftUI view is fixed-size (460×600); do NOT let the hosting controller
        // resize the window from content. Auto-sizing kicked off a constraint recompute
        // on the NSHostingView that aborted in _postWindowNeedsUpdateConstraints.
        hostingController.sizingOptions = []

        // Build the window with its final style mask + content size up front. Reassigning
        // styleMask after `NSWindow(contentViewController:)` also triggers that same crash.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "TokenCounter 설정"
        win.contentViewController = hostingController
        win.delegate = self
        win.center()
        win.isReleasedWhenClosed = false

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
