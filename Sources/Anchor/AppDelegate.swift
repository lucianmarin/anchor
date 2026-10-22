import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var refreshTimer: Timer?
    private var currentApps: [DockAppItem] = []
    private var lastTotalNotifications: Int = -1
    private var lastActiveBundleId: String?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        registerWorkspaceNotifications()
        refreshState(force: true)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState(force: false)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Workspace Observation

    private func registerWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            self,
            selector: #selector(handleWorkspaceEvent(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleWorkspaceEvent(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleWorkspaceEvent(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func handleWorkspaceEvent(_ notification: Notification) {
        refreshState(force: true)
    }

    // MARK: - Status Item & Menu Refresh

    private func refreshState(force: Bool) {
        let result = DockManager.shared.fetchDockApps()
        currentApps = result.apps

        let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if force || result.totalNotifications != lastTotalNotifications || frontBundleId != lastActiveBundleId {
            lastTotalNotifications = result.totalNotifications
            lastActiveBundleId = frontBundleId
            updateStatusBarIcon(totalNotifications: result.totalNotifications)
        }
    }

    private func updateStatusBarIcon(totalNotifications: Int) {
        guard let button = statusItem.button else { return }
        let activeIcon = DockManager.shared.activeAppIcon()
        button.image = BadgeRenderer.makeMenuBarImage(
            appIcon: activeIcon,
            notificationCount: totalNotifications
        )
        button.toolTip = totalNotifications > 0
            ? "Anchor (\(totalNotifications) unread notifications)"
            : "Anchor"
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        let result = DockManager.shared.fetchDockApps()
        currentApps = result.apps
        updateStatusBarIcon(totalNotifications: result.totalNotifications)
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let pinnedApps = currentApps.filter(\.isPinned)
        let unpinnedRunningApps = currentApps.filter { !$0.isPinned }

        for (index, app) in pinnedApps.enumerated() {
            menu.addItem(makeAppMenuItem(for: app, index: index))
        }

        if !unpinnedRunningApps.isEmpty {
            menu.addItem(.separator())
            let offset = pinnedApps.count
            for (idx, app) in unpinnedRunningApps.enumerated() {
                menu.addItem(makeAppMenuItem(for: app, index: offset + idx))
            }
        }

        menu.addItem(.separator())

        let disableDockItem = NSMenuItem(
            title: "Disable Dock",
            action: #selector(toggleDisableDock(_:)),
            keyEquivalent: ""
        )
        disableDockItem.target = self
        disableDockItem.state = DockManager.shared.isDockDisabled() ? .on : .off
        menu.addItem(disableDockItem)

        let quitItem = NSMenuItem(
            title: "Quit Anchor",
            action: #selector(quitAnchor(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeAppMenuItem(for app: DockAppItem, index: Int) -> NSMenuItem {
        let item = NSMenuItem(
            title: app.name,
            action: #selector(selectDockApp(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = index
        item.image = BadgeRenderer.makeMenuAppIcon(appIcon: app.icon, isRunning: app.isRunning)
        item.attributedTitle = BadgeRenderer.makeMenuItemAttributedTitle(
            appName: app.name,
            badgeText: app.notificationBadgeText
        )
        return item
    }

    // MARK: - Actions

    @objc private func selectDockApp(_ sender: NSMenuItem) {
        let index = sender.tag
        guard currentApps.indices.contains(index) else { return }
        DockManager.shared.openOrActivate(currentApps[index])
    }

    @objc private func toggleDisableDock(_ sender: NSMenuItem) {
        let newState = !DockManager.shared.isDockDisabled()
        DockManager.shared.setDockDisabled(newState)
    }

    @objc private func quitAnchor(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
