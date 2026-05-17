import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var model: ScannerModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scannerModel = ScannerModel()
        model = scannerModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let img = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                              accessibilityDescription: "Web Finder")
            img?.isTemplate = true
            button.image = img
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 340, height: 460)
        popover?.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(scannerModel)
        )
        popover?.behavior = .transient
        popover?.animates = true

        // Pre-scan immediately on launch so results are ready when the user clicks
        scannerModel.scan()
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
