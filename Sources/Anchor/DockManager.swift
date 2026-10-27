import AppKit
import ApplicationServices
import Foundation

public struct DockAppItem: Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let url: URL
    public let icon: NSImage
    public let isRunning: Bool
    public let isPinned: Bool
    public let notificationCount: Int
    public let notificationBadgeText: String?

    public static func == (lhs: DockAppItem, rhs: DockAppItem) -> Bool {
        lhs.name == rhs.name &&
        lhs.bundleIdentifier == rhs.bundleIdentifier &&
        lhs.url == rhs.url &&
        lhs.isRunning == rhs.isRunning &&
        lhs.isPinned == rhs.isPinned &&
        lhs.notificationCount == rhs.notificationCount &&
        lhs.notificationBadgeText == rhs.notificationBadgeText
    }
}

public enum BadgeCountParser {
    /// Sanitizes raw status label strings and extracts a numeric notification count and display text.
    public static func parse(_ rawLabel: String?) -> (count: Int, badgeText: String?) {
        guard let rawLabel else { return (0, nil) }
        let trimmed = cleanInvisibleCharacters(rawLabel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "<null>", trimmed != "null" else {
            return (0, nil)
        }

        let digitsOnly = trimmed.filter(\.isNumber)
        if let value = Int(digitsOnly), value > 0 {
            return (value, "\(value)")
        }
        if trimmed == "0" {
            return (0, nil)
        }
        // Non-numeric non-empty status badge (e.g. "•" or "!") counts as 1 notification.
        return (1, "1")
    }

    public static func cleanInvisibleCharacters(_ text: String) -> String {
        let invisibleScalars: Set<UnicodeScalar> = [
            "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{FEFF}"
        ]
        return String(text.unicodeScalars.filter { !invisibleScalars.contains($0) })
    }
}

public final class DockManager {
    public static let shared = DockManager()

    private static let dockDomain = "com.apple.dock"
    private static let finderBundleId = "com.apple.finder"
    private static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    private static let disabledDockDelay: Float = 3600.0
    public static let showPreviousAppDefaultsKey = "showPreviousApp"
    public static let previousAppsCountDefaultsKey = "previousAppsCount"
    public static let maxPreviousAppsCount = 4
    public static let defaultPreviousAppsCount = 1
    public static let previousAppsCountNames = ["Zero", "One", "Two", "Three", "Four"]

    // Private LaunchServices functions to read Dock badge counts in-process without requiring Accessibility permissions.
    private typealias LSASNCreateWithPidFn = @convention(c) (CFAllocator?, pid_t) -> AnyObject?
    private typealias LSCopyApplicationInformationItemFn = @convention(c) (Int, AnyObject, CFString) -> AnyObject?

    private let lsCreateASN: LSASNCreateWithPidFn?
    private let lsCopyAppInfo: LSCopyApplicationInformationItemFn?

    public init() {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices"
        if let handle = dlopen(path, RTLD_LAZY),
           let asnSym = dlsym(handle, "_LSASNCreateWithPid"),
           let infoSym = dlsym(handle, "_LSCopyApplicationInformationItem") {
            self.lsCreateASN = unsafeBitCast(asnSym, to: LSASNCreateWithPidFn.self)
            self.lsCopyAppInfo = unsafeBitCast(infoSym, to: LSCopyApplicationInformationItemFn.self)
        } else {
            self.lsCreateASN = nil
            self.lsCopyAppInfo = nil
        }
    }

    // MARK: - Active Application

    public func activeAppIcon() -> NSImage {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let icon = frontmost.icon {
            return icon
        }
        return NSWorkspace.shared.icon(forFile: Self.finderURL.path)
    }

    // MARK: - Dock App List & Notifications

    public func fetchDockApps() -> (apps: [DockAppItem], totalNotifications: Int) {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        let selfBundleId = Bundle.main.bundleIdentifier
        let selfPID = ProcessInfo.processInfo.processIdentifier

        var runningByBundleId: [String: NSRunningApplication] = [:]
        var runningByPath: [String: NSRunningApplication] = [:]
        for app in runningApps {
            if let bid = app.bundleIdentifier {
                runningByBundleId[bid] = app
            }
            if let path = app.bundleURL?.standardizedFileURL.path {
                runningByPath[path] = app
            }
        }

        let axBadgesByTitle = fetchAccessibilityDockBadges()

        var items: [DockAppItem] = []
        var seenBundleIds: Set<String> = []
        var seenPaths: Set<String> = []

        // 1. Finder is always first in the macOS Dock
        let finderRunning = runningByBundleId[Self.finderBundleId]
        let finderName = BadgeCountParser.cleanInvisibleCharacters(
            finderRunning?.localizedName ?? "Finder"
        )
        let finderBadge = resolveBadge(
            for: finderRunning,
            appName: finderName,
            axBadgesByTitle: axBadgesByTitle
        )
        let finderIcon = finderRunning?.icon ?? NSWorkspace.shared.icon(forFile: Self.finderURL.path)
        items.append(
            DockAppItem(
                name: finderName,
                bundleIdentifier: Self.finderBundleId,
                url: finderRunning?.bundleURL ?? Self.finderURL,
                icon: finderIcon,
                isRunning: finderRunning != nil,
                isPinned: true,
                notificationCount: finderBadge.count,
                notificationBadgeText: finderBadge.badgeText
            )
        )
        seenBundleIds.insert(Self.finderBundleId)
        seenPaths.insert(Self.finderURL.standardizedFileURL.path)

        // 2. Pinned apps from com.apple.dock persistent-apps
        let pinnedEntries = Self.parsePersistentApps(from: loadDockPersistentApps())
        for entry in pinnedEntries {
            let standardizedPath = entry.url.standardizedFileURL.path
            if let bid = entry.bundleIdentifier, seenBundleIds.contains(bid) {
                continue
            }
            if seenPaths.contains(standardizedPath) {
                continue
            }

            let runningApp = (entry.bundleIdentifier.flatMap { runningByBundleId[$0] })
                ?? runningByPath[standardizedPath]
            let resolvedBundleId = entry.bundleIdentifier
                ?? runningApp?.bundleIdentifier
                ?? Bundle(url: entry.url)?.bundleIdentifier

            if let resolvedBundleId {
                if seenBundleIds.contains(resolvedBundleId) {
                    continue
                }
                seenBundleIds.insert(resolvedBundleId)
            }
            seenPaths.insert(standardizedPath)

            let rawName = runningApp?.localizedName ?? entry.label
            let cleanName = BadgeCountParser.cleanInvisibleCharacters(rawName)
            let icon = runningApp?.icon ?? NSWorkspace.shared.icon(forFile: entry.url.path)
            let badge = resolveBadge(
                for: runningApp,
                appName: cleanName,
                axBadgesByTitle: axBadgesByTitle
            )

            items.append(
                DockAppItem(
                    name: cleanName,
                    bundleIdentifier: resolvedBundleId,
                    url: runningApp?.bundleURL ?? entry.url,
                    icon: icon,
                    isRunning: runningApp != nil,
                    isPinned: true,
                    notificationCount: badge.count,
                    notificationBadgeText: badge.badgeText
                )
            )
        }

        // 3. Running unpinned regular apps
        for runningApp in runningApps {
            if runningApp.processIdentifier == selfPID {
                continue
            }
            if let bid = runningApp.bundleIdentifier, bid == selfBundleId {
                continue
            }
            if let bid = runningApp.bundleIdentifier, seenBundleIds.contains(bid) {
                continue
            }
            let appURL = runningApp.bundleURL ?? URL(fileURLWithPath: "/Applications")
            let standardizedPath = appURL.standardizedFileURL.path
            if seenPaths.contains(standardizedPath) {
                continue
            }

            if let bid = runningApp.bundleIdentifier {
                seenBundleIds.insert(bid)
            }
            seenPaths.insert(standardizedPath)

            let rawName = runningApp.localizedName ?? appURL.deletingPathExtension().lastPathComponent
            let cleanName = BadgeCountParser.cleanInvisibleCharacters(rawName)
            let icon = runningApp.icon ?? NSWorkspace.shared.icon(forFile: appURL.path)
            let badge = resolveBadge(
                for: runningApp,
                appName: cleanName,
                axBadgesByTitle: axBadgesByTitle
            )

            items.append(
                DockAppItem(
                    name: cleanName,
                    bundleIdentifier: runningApp.bundleIdentifier,
                    url: appURL,
                    icon: icon,
                    isRunning: true,
                    isPinned: false,
                    notificationCount: badge.count,
                    notificationBadgeText: badge.badgeText
                )
            )
        }

        let totalNotifications = items.reduce(0) { $0 + $1.notificationCount }
        return (items, totalNotifications)
    }

    public struct PersistentAppEntry: Equatable {
        public let label: String
        public let bundleIdentifier: String?
        public let url: URL
    }

    public static func parsePersistentApps(from rawArray: [[String: Any]]) -> [PersistentAppEntry] {
        var entries: [PersistentAppEntry] = []
        for item in rawArray {
            guard let tileData = item["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String,
                  let url = URL(string: urlString) else {
                continue
            }
            let bundleId = tileData["bundle-identifier"] as? String
            let label = (tileData["file-label"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            entries.append(
                PersistentAppEntry(
                    label: BadgeCountParser.cleanInvisibleCharacters(label),
                    bundleIdentifier: bundleId,
                    url: url
                )
            )
        }
        return entries
    }

    private func loadDockPersistentApps() -> [[String: Any]] {
        if let suite = UserDefaults(suiteName: Self.dockDomain),
           let apps = suite.array(forKey: "persistent-apps") as? [[String: Any]] {
            return apps
        }
        let plistPath = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
        if let dict = NSDictionary(contentsOfFile: plistPath),
           let apps = dict["persistent-apps"] as? [[String: Any]] {
            return apps
        }
        return []
    }

    // MARK: - Notification Badge Lookup

    private func resolveBadge(
        for runningApp: NSRunningApplication?,
        appName: String,
        axBadgesByTitle: [String: String]
    ) -> (count: Int, badgeText: String?) {
        if let runningApp,
           let rawLabel = fetchLaunchServicesStatusLabel(pid: runningApp.processIdentifier) {
            let parsed = BadgeCountParser.parse(rawLabel)
            if parsed.count > 0 {
                return parsed
            }
        }
        if let axLabel = axBadgesByTitle[appName] {
            return BadgeCountParser.parse(axLabel)
        }
        return (0, nil)
    }

    private func fetchLaunchServicesStatusLabel(pid: pid_t) -> String? {
        guard let lsCreateASN, let lsCopyAppInfo,
              let asn = lsCreateASN(kCFAllocatorDefault, pid) else {
            return nil
        }
        guard let statusObj = lsCopyAppInfo(-2, asn, "StatusLabel" as CFString) as? NSDictionary,
              let label = statusObj["label"] as? String else {
            return nil
        }
        return label
    }

    /// Fallback lookup via Accessibility API (`AXStatusLabel` on the Dock process) when Accessibility is granted.
    private func fetchAccessibilityDockBadges() -> [String: String] {
        guard AXIsProcessTrusted() else { return [:] }
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockDomain).first else {
            return [:]
        }

        let axDock = AXUIElementCreateApplication(dockApp.processIdentifier)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axDock, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return [:]
        }

        var result: [String: String] = [:]
        for child in children {
            var subchildrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &subchildrenRef) == .success,
                  let items = subchildrenRef as? [AXUIElement] else {
                continue
            }
            for item in items {
                var titleRef: CFTypeRef?
                var statusRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   AXUIElementCopyAttributeValue(item, "AXStatusLabel" as CFString, &statusRef) == .success,
                   let status = statusRef as? String {
                    let cleanTitle = BadgeCountParser.cleanInvisibleCharacters(title)
                    result[cleanTitle] = status
                }
            }
        }
        return result
    }

    // MARK: - Launching & Activating Apps

    public func openOrActivate(_ item: DockAppItem) {
        openOrActivate(bundleIdentifier: item.bundleIdentifier, url: item.url)
    }

    public func openOrActivate(bundleIdentifier: String?, url: URL) {
        if let bundleId = bundleIdentifier,
           let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            // Also call openApplication so reopened windows (like Finder or minimized apps) unminimize/reopen cleanly
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    // MARK: - Previous Apps Preference

    public func previousAppsCount(defaults: UserDefaults = .standard) -> Int {
        if let rawValue = defaults.object(forKey: Self.previousAppsCountDefaultsKey) as? NSNumber {
            return min(max(rawValue.intValue, 0), Self.maxPreviousAppsCount)
        }
        if defaults.object(forKey: Self.showPreviousAppDefaultsKey) != nil {
            return defaults.bool(forKey: Self.showPreviousAppDefaultsKey) ? Self.defaultPreviousAppsCount : 0
        }
        return Self.defaultPreviousAppsCount
    }

    public func setPreviousAppsCount(_ count: Int, defaults: UserDefaults = .standard) {
        let clamped = min(max(count, 0), Self.maxPreviousAppsCount)
        defaults.set(clamped, forKey: Self.previousAppsCountDefaultsKey)
        defaults.set(clamped > 0, forKey: Self.showPreviousAppDefaultsKey)
    }

    public func isPreviousAppEnabled(defaults: UserDefaults = .standard) -> Bool {
        previousAppsCount(defaults: defaults) > 0
    }

    public func setPreviousAppEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        setPreviousAppsCount(enabled ? Self.defaultPreviousAppsCount : 0, defaults: defaults)
    }

    // MARK: - Disable / Enable System Dock

    public func isDockDisabled() -> Bool {
        guard let suite = UserDefaults(suiteName: Self.dockDomain) else {
            return false
        }
        let autohide = suite.bool(forKey: "autohide")
        guard let delayObj = suite.object(forKey: "autohide-delay") as? NSNumber else {
            return false
        }
        return autohide && delayObj.floatValue >= Self.disabledDockDelay
    }

    public func setDockDisabled(_ disabled: Bool) {
        if disabled {
            runDefaultsCommand(arguments: ["write", Self.dockDomain, "autohide", "-bool", "true"])
            runDefaultsCommand(arguments: ["write", Self.dockDomain, "autohide-delay", "-float", "3600"])
        } else {
            runDefaultsCommand(arguments: ["delete", Self.dockDomain, "autohide-delay"])
            runDefaultsCommand(arguments: ["write", Self.dockDomain, "autohide", "-bool", "false"])
        }
        restartSystemDock()
    }

    private func runDefaultsCommand(arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }

    private func restartSystemDock() {
        if let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockDomain).first {
            dockApp.terminate()
        }
    }
}
