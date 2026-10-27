import AppKit

public struct TrackedAppInfo: Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let url: URL
    public let icon: NSImage

    public init(name: String, bundleIdentifier: String?, url: URL, icon: NSImage) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.icon = icon
    }

    public func isSameApplication(as other: TrackedAppInfo) -> Bool {
        if let lhsId = bundleIdentifier, let rhsId = other.bundleIdentifier {
            return lhsId == rhsId
        }
        return url.standardizedFileURL.path == other.url.standardizedFileURL.path
    }

    public static func == (lhs: TrackedAppInfo, rhs: TrackedAppInfo) -> Bool {
        lhs.name == rhs.name &&
        lhs.bundleIdentifier == rhs.bundleIdentifier &&
        lhs.url.standardizedFileURL.path == rhs.url.standardizedFileURL.path
    }
}

public struct ActiveAppHistoryTracker {
    public static let defaultMaxPreviousApps = 4

    public private(set) var currentApp: TrackedAppInfo?
    public private(set) var previousApps: [TrackedAppInfo]
    public let maxPreviousApps: Int

    public var previousApp: TrackedAppInfo? {
        previousApps.first
    }

    public init(
        currentApp: TrackedAppInfo? = nil,
        previousApps: [TrackedAppInfo] = [],
        maxPreviousApps: Int = Self.defaultMaxPreviousApps
    ) {
        self.currentApp = currentApp
        self.maxPreviousApps = max(0, maxPreviousApps)
        self.previousApps = Array(previousApps.prefix(self.maxPreviousApps))
    }

    public init(currentApp: TrackedAppInfo?, previousApp: TrackedAppInfo?) {
        self.init(
            currentApp: currentApp,
            previousApps: previousApp.map { [$0] } ?? []
        )
    }

    /// Records the currently active app and updates `previousApps` (most recent first, deduplicated)
    /// when switching to a different app.
    /// Returns `true` if either `currentApp` or `previousApps` changed.
    @discardableResult
    public mutating func recordActivation(_ app: TrackedAppInfo) -> Bool {
        guard let existingCurrent = currentApp else {
            currentApp = app
            return true
        }
        if existingCurrent.isSameApplication(as: app) {
            if existingCurrent != app {
                currentApp = app
                return true
            }
            return false
        }
        var updatedPrevious = previousApps.filter {
            !$0.isSameApplication(as: app) && !$0.isSameApplication(as: existingCurrent)
        }
        updatedPrevious.insert(existingCurrent, at: 0)
        if updatedPrevious.count > maxPreviousApps {
            updatedPrevious = Array(updatedPrevious.prefix(maxPreviousApps))
        }
        previousApps = updatedPrevious
        currentApp = app
        return true
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var previousAppStatusItems: [NSStatusItem] = []
    private let statusMenu = NSMenu()
    private var refreshTimer: Timer?
    private var currentApps: [DockAppItem] = []
    private var lastTotalNotifications: Int = -1
    private var appHistory = ActiveAppHistoryTracker()

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
        for item in previousAppStatusItems {
            NSStatusBar.system.removeStatusItem(item)
        }
        previousAppStatusItems.removeAll()
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
        if notification.name == NSWorkspace.didActivateApplicationNotification,
           let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           let tracked = makeTrackedAppInfo(from: activatedApp) {
            _ = appHistory.recordActivation(tracked)
        }
        refreshState(force: true)
    }

    private func makeTrackedAppInfo(from runningApp: NSRunningApplication) -> TrackedAppInfo? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if runningApp.processIdentifier == selfPID {
            return nil
        }
        if let selfBundleId = Bundle.main.bundleIdentifier,
           runningApp.bundleIdentifier == selfBundleId {
            return nil
        }
        guard let url = runningApp.bundleURL else {
            return nil
        }
        let rawName = runningApp.localizedName ?? url.deletingPathExtension().lastPathComponent
        let cleanName = BadgeCountParser.cleanInvisibleCharacters(rawName)
        let icon = runningApp.icon ?? NSWorkspace.shared.icon(forFile: url.path)
        return TrackedAppInfo(
            name: cleanName,
            bundleIdentifier: runningApp.bundleIdentifier,
            url: url,
            icon: icon
        )
    }

    // MARK: - Status Item & Menu Refresh

    private func refreshState(force: Bool) {
        let result = DockManager.shared.fetchDockApps()
        currentApps = result.apps

        var historyChanged = false
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let tracked = makeTrackedAppInfo(from: frontApp) {
            historyChanged = appHistory.recordActivation(tracked)
        }

        if force || result.totalNotifications != lastTotalNotifications || historyChanged {
            lastTotalNotifications = result.totalNotifications
            updateStatusBarIcon(totalNotifications: result.totalNotifications)
            updatePreviousAppStatusItem()
        }
    }

    private func updateStatusBarIcon(totalNotifications: Int) {
        guard let button = statusItem.button else { return }
        let activeIcon = appHistory.currentApp?.icon ?? DockManager.shared.activeAppIcon()
        button.image = BadgeRenderer.makeMenuBarImage(
            appIcon: activeIcon,
            notificationCount: totalNotifications
        )
        button.toolTip = totalNotifications > 0
            ? "Anchor (\(totalNotifications) unread notifications)"
            : "Anchor"
    }

    private func updatePreviousAppStatusItem() {
        let configuredCount = DockManager.shared.previousAppsCount()
        let visibleApps = Array(appHistory.previousApps.prefix(configuredCount))

        while previousAppStatusItems.count > visibleApps.count {
            let removed = previousAppStatusItems.removeLast()
            NSStatusBar.system.removeStatusItem(removed)
        }

        while previousAppStatusItems.count < visibleApps.count {
            let newItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            newItem.menu = nil
            if let button = newItem.button {
                button.target = self
                button.action = #selector(activatePreviousApp(_:))
            }
            previousAppStatusItems.append(newItem)
        }

        for (index, app) in visibleApps.enumerated() {
            if let button = previousAppStatusItems[index].button {
                button.tag = index
                button.image = BadgeRenderer.makeFadedMenuBarIcon(appIcon: app.icon)
                button.toolTip = "Switch to \(app.name)"
            }
        }
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

        let previousAppsItem = NSMenuItem(
            title: "Previous Apps",
            action: nil,
            keyEquivalent: ""
        )
        let previousAppsSubmenu = NSMenu(title: "Previous Apps")
        let selectedPreviousCount = DockManager.shared.previousAppsCount()
        for (count, label) in DockManager.previousAppsCountNames.enumerated() {
            let optionItem = NSMenuItem(
                title: label,
                action: #selector(selectPreviousAppsCount(_:)),
                keyEquivalent: ""
            )
            optionItem.target = self
            optionItem.tag = count
            optionItem.state = (count == selectedPreviousCount) ? .on : .off
            previousAppsSubmenu.addItem(optionItem)
        }
        previousAppsItem.submenu = previousAppsSubmenu
        menu.addItem(previousAppsItem)

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

    @objc private func activatePreviousApp(_ sender: NSStatusBarButton) {
        let index = sender.tag
        guard appHistory.previousApps.indices.contains(index) else { return }
        let targetApp = appHistory.previousApps[index]
        DockManager.shared.openOrActivate(
            bundleIdentifier: targetApp.bundleIdentifier,
            url: targetApp.url
        )
    }

    @objc private func selectDockApp(_ sender: NSMenuItem) {
        let index = sender.tag
        guard currentApps.indices.contains(index) else { return }
        DockManager.shared.openOrActivate(currentApps[index])
    }

    @objc private func selectPreviousAppsCount(_ sender: NSMenuItem) {
        DockManager.shared.setPreviousAppsCount(sender.tag)
        updatePreviousAppStatusItem()
    }

    @objc private func toggleDisableDock(_ sender: NSMenuItem) {
        let newState = !DockManager.shared.isDockDisabled()
        DockManager.shared.setDockDisabled(newState)
    }

    @objc private func quitAnchor(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
