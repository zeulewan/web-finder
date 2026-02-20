import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                              accessibilityDescription: "Web Scanner")
            img?.isTemplate = true
            button.image = img
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hostingController = NSHostingController(rootView: ContentView())
        hostingController.sizingOptions = .preferredContentSize

        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.behavior = .transient // Closes when clicking outside - automatic, no blur hacks needed
        popover.animates = true
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
