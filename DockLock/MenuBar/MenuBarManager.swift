import AppKit
import SwiftUI
import Combine

class MenuBarManager {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "DockLock")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Pin the root view to an explicit size so SwiftUI never triggers a
        // resize measurement during NSPopover's layout pass, which causes the
        // "-layoutSubtreeIfNeeded called during layout" recursion warning.
        let rootView = MenuBarView()
            .frame(width: 280)
            .fixedSize(horizontal: true, vertical: false)

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = []
        hostingController.preferredContentSize = NSSize(width: 280, height: 220)

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 220)
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hostingController
        self.popover = popover

        observePanicState()
    }

    // MARK: - Icon state

    private func observePanicState() {
        PanicModeManager.shared.$isActive
            .receive(on: RunLoop.main)
            .sink { [weak self] isActive in
                self?.updateIcon(panicActive: isActive)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(panicActive: Bool) {
        let symbolName = panicActive ? "lock.shield.fill" : "lock.shield"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DockLock")
        // Must be template so it renders correctly in both light and dark menu bars
        image?.isTemplate = true
        statusItem?.button?.image = image
        // Do NOT use contentTintColor — it conflicts with template image rendering
        // and makes the icon invisible. The filled/outline symbol difference is enough.
    }

    // MARK: - Popover

    func closePopover() {
        popover?.performClose(nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
