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
    }
}
