import AppKit
import SwiftUI
import Combine

class MenuBarManager {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    /// Height when first-run welcome is shown (3 steps + header + footer).
    private static let welcomeHeight: CGFloat = 220
    /// Height for the normal main view (header + panic button + footer).
    private static let mainHeight: CGFloat = 130

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "DockLock")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hasShownWelcome = UserDefaults.standard.bool(forKey: "hasShownWelcome")
        let initialHeight = hasShownWelcome ? Self.mainHeight : Self.welcomeHeight

        // Pin the root view to an explicit size so SwiftUI never triggers a
        // resize measurement during NSPopover's layout pass, which causes the
        // "-layoutSubtreeIfNeeded called during layout" recursion warning.
        let rootView = MenuBarView()
            .frame(width: 280)
            .fixedSize(horizontal: true, vertical: false)

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = []
        hostingController.preferredContentSize = NSSize(width: 280, height: initialHeight)

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: initialHeight)
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hostingController
        self.popover = popover

        observePanicState()
        observeWelcomeState()
        observeMenuBarStats()
    }

    // MARK: - Welcome state

    private func observeWelcomeState() {
        // Resize the popover when the user dismisses the welcome screen.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in UserDefaults.standard.bool(forKey: "hasShownWelcome") }
            .removeDuplicates()
            .sink { [weak self] hasShown in
                guard let self, hasShown else { return }
                let size = NSSize(width: 280, height: Self.mainHeight)
                self.popover?.contentViewController?.preferredContentSize = size
                self.popover?.contentSize = size
            }
            .store(in: &cancellables)
    }

    // MARK: - Menubar stats

    private func observeMenuBarStats() {
        // Combine settings toggle + RSSI + countdown into a single update stream.
        Publishers.CombineLatest4(
            SettingsStore.shared.$showMenuBarStats,
            BluetoothMonitor.shared.$currentRSSI,
            BluetoothMonitor.shared.$isDeviceVisible,
            LockTrigger.shared.$secondsRemaining
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] showStats, rssi, visible, seconds in
            self?.updateMenuBarTitle(
                showStats: showStats,
                rssi: rssi,
                visible: visible,
                countdown: seconds
            )
        }
        .store(in: &cancellables)
    }

    private func updateMenuBarTitle(showStats: Bool, rssi: Int, visible: Bool, countdown: Int) {
        guard showStats, BluetoothMonitor.shared.pairedDeviceUUID != nil else {
            statusItem?.button?.title = ""
            return
        }
        if LockTrigger.shared.isCountingDown {
            statusItem?.button?.title = " \(countdown)s"
        } else if visible, rssi != 0 {
            statusItem?.button?.title = " \(rssi)"
        } else {
            statusItem?.button?.title = ""
        }
    }

    // MARK: - Icon state

    private func observePanicState() {
        PanicModeManager.shared.$isActive
            .receive(on: DispatchQueue.main)
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
