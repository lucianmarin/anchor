import XCTest
@testable import Anchor

final class AnchorTests: XCTestCase {
    func testBadgeCountParserNumericAndFormattedStrings() {
        XCTAssertEqual(BadgeCountParser.parse(nil).count, 0)
        XCTAssertNil(BadgeCountParser.parse(nil).badgeText)

        XCTAssertEqual(BadgeCountParser.parse("").count, 0)
        XCTAssertEqual(BadgeCountParser.parse("<null>").count, 0)
        XCTAssertEqual(BadgeCountParser.parse("0").count, 0)

        let simple = BadgeCountParser.parse("7")
        XCTAssertEqual(simple.count, 7)
        XCTAssertEqual(simple.badgeText, "7")

        let formatted = BadgeCountParser.parse("99+")
        XCTAssertEqual(formatted.count, 99)
        XCTAssertEqual(formatted.badgeText, "99")

        let nonNumeric = BadgeCountParser.parse("•")
        XCTAssertEqual(nonNumeric.count, 1)
        XCTAssertEqual(nonNumeric.badgeText, "1")
    }

    func testCleanInvisibleCharactersStripsDirectionalMarks() {
        let raw = "\u{200E}WhatsApp\u{200F}"
        XCTAssertEqual(BadgeCountParser.cleanInvisibleCharacters(raw), "WhatsApp")
    }

    func testParsePersistentAppsExtractsOrderAndMetadata() {
        let raw: [[String: Any]] = [
            [
                "tile-data": [
                    "file-label": "\u{200E}WhatsApp",
                    "bundle-identifier": "net.whatsapp.WhatsApp",
                    "file-data": [
                        "_CFURLString": "file:///Applications/WhatsApp.app/"
                    ]
                ]
            ],
            [
                "tile-data": [
                    "file-label": "Calendar",
                    "bundle-identifier": "com.apple.iCal",
                    "file-data": [
                        "_CFURLString": "file:///System/Applications/Calendar.app/"
                    ]
                ]
            ]
        ]

        let entries = DockManager.parsePersistentApps(from: raw)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].label, "WhatsApp")
        XCTAssertEqual(entries[0].bundleIdentifier, "net.whatsapp.WhatsApp")
        XCTAssertEqual(entries[0].url.path, "/Applications/WhatsApp.app")
        XCTAssertEqual(entries[1].label, "Calendar")
        XCTAssertEqual(entries[1].bundleIdentifier, "com.apple.iCal")
    }

    func testBadgeRendererProducesMenuBarAndMenuImages() {
        let dummyIcon = NSImage(size: NSSize(width: 32, height: 32))
        let noBadgeMenuIcon = BadgeRenderer.makeMenuBarImage(appIcon: dummyIcon, notificationCount: 0)
        XCTAssertEqual(noBadgeMenuIcon.size.width, 18)

        let withBadgeMenuIcon = BadgeRenderer.makeMenuBarImage(appIcon: dummyIcon, notificationCount: 12)
        XCTAssertGreaterThan(withBadgeMenuIcon.size.width, 18)

        let attrTitle = BadgeRenderer.makeMenuItemAttributedTitle(appName: "Messages", badgeText: "3")
        XCTAssertTrue(attrTitle.string.hasPrefix("Messages"))

        let fadedIcon = BadgeRenderer.makeFadedMenuBarIcon(appIcon: dummyIcon)
        XCTAssertEqual(fadedIcon.size, NSSize(width: 18, height: 18))
    }

    func testActiveAppHistoryTrackerTracksPreviousAndCurrentApps() {
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        let safari = TrackedAppInfo(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            url: URL(fileURLWithPath: "/Applications/Safari.app"),
            icon: icon
        )
        let terminal = TrackedAppInfo(
            name: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            icon: icon
        )
        let mail = TrackedAppInfo(
            name: "Mail",
            bundleIdentifier: "com.apple.mail",
            url: URL(fileURLWithPath: "/System/Applications/Mail.app"),
            icon: icon
        )

        var tracker = ActiveAppHistoryTracker()
        XCTAssertNil(tracker.currentApp)
        XCTAssertNil(tracker.previousApp)

        XCTAssertTrue(tracker.recordActivation(safari))
        XCTAssertEqual(tracker.currentApp, safari)
        XCTAssertNil(tracker.previousApp)

        // Re-activating the same app should not overwrite previousApp
        XCTAssertFalse(tracker.recordActivation(safari))
        XCTAssertEqual(tracker.currentApp, safari)
        XCTAssertNil(tracker.previousApp)

        // Switching to Terminal sets Safari as previousApp
        XCTAssertTrue(tracker.recordActivation(terminal))
        XCTAssertEqual(tracker.currentApp, terminal)
        XCTAssertEqual(tracker.previousApp, safari)

        // Repeating Terminal keeps Safari as previousApp
        XCTAssertFalse(tracker.recordActivation(terminal))
        XCTAssertEqual(tracker.currentApp, terminal)
        XCTAssertEqual(tracker.previousApp, safari)

        // Switching to Mail sets Terminal as previousApp
        XCTAssertTrue(tracker.recordActivation(mail))
        XCTAssertEqual(tracker.currentApp, mail)
        XCTAssertEqual(tracker.previousApp, terminal)
    }

    func testPreviousAppPreferenceDefaultsToTrueAndPersistsToggle() {
        let suiteName = "com.lucianmarin.AnchorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(DockManager.shared.isPreviousAppEnabled(defaults: defaults))

        DockManager.shared.setPreviousAppEnabled(false, defaults: defaults)
        XCTAssertFalse(DockManager.shared.isPreviousAppEnabled(defaults: defaults))

        DockManager.shared.setPreviousAppEnabled(true, defaults: defaults)
        XCTAssertTrue(DockManager.shared.isPreviousAppEnabled(defaults: defaults))
    }
}
