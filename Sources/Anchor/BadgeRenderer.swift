import AppKit

public enum BadgeRenderer {
    private static let iconSize = NSSize(width: 18, height: 18)
    private static let badgeHeight: CGFloat = 14
    private static let badgeMinWidth: CGFloat = 14
    private static let badgeHorizontalPadding: CGFloat = 4.5
    private static let badgeSpacing: CGFloat = 4

    /// Renders the notification count pill badge used by both the menu bar icon and per-app menu items.
    public static func makeBadgePillImage(text: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]

        let attrString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attrString.size()
        let pillWidth = max(badgeMinWidth, ceil(textSize.width) + badgeHorizontalPadding * 2)
        let pillSize = NSSize(width: pillWidth, height: badgeHeight)

        let image = NSImage(size: pillSize, flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: badgeHeight / 2,
                yRadius: badgeHeight / 2
            )
            NSColor.systemRed.setFill()
            path.fill()

            let textRect = NSRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2 - 0.5,
                width: textSize.width,
                height: textSize.height
            )
            attrString.draw(in: textRect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Renders the menu bar status item image: the active app icon and, if total notifications > 0,
    /// the notification counter pill in the exact same style as the app menu items.
    public static func makeMenuBarImage(appIcon: NSImage, notificationCount: Int) -> NSImage {
        let badgeText = notificationCount > 0 ? "\(notificationCount)" : nil
        return makeIconWithBadgeImage(appIcon: appIcon, badgeText: badgeText)
    }

    /// Renders an 18x18 app icon optionally followed by the notification badge pill.
    public static func makeIconWithBadgeImage(appIcon: NSImage, badgeText: String?) -> NSImage {
        guard let badgeText, !badgeText.isEmpty else {
            let image = NSImage(size: iconSize, flipped: false) { rect in
                appIcon.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                return true
            }
            image.isTemplate = false
            return image
        }

        let badgeImage = makeBadgePillImage(text: badgeText)
        let totalWidth = iconSize.width + badgeSpacing + badgeImage.size.width
        let canvasSize = NSSize(width: totalWidth, height: iconSize.height)

        let combined = NSImage(size: canvasSize, flipped: false) { _ in
            let iconRect = NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height)
            appIcon.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )

            let badgeY = (iconSize.height - badgeImage.size.height) / 2
            let badgeRect = NSRect(
                x: iconSize.width + badgeSpacing,
                y: badgeY,
                width: badgeImage.size.width,
                height: badgeImage.size.height
            )
            badgeImage.draw(
                in: badgeRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }
        combined.isTemplate = false
        return combined
    }

    /// Renders an app icon for a menu item, with an optional subtle Dock-style running indicator dot.
    public static func makeMenuAppIcon(appIcon: NSImage, isRunning: Bool) -> NSImage {
        let canvasSize = NSSize(width: 22, height: 18)
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            if isRunning {
                let dotSize: CGFloat = 3.5
                let dotRect = NSRect(
                    x: 0,
                    y: (canvasSize.height - dotSize) / 2,
                    width: dotSize,
                    height: dotSize
                )
                let dotPath = NSBezierPath(ovalIn: dotRect)
                NSColor.labelColor.withAlphaComponent(0.8).setFill()
                dotPath.fill()
            }

            let iconRect = NSRect(
                x: 4,
                y: 0,
                width: iconSize.width,
                height: iconSize.height
            )
            appIcon.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Builds the menu item attributed title with the app name and (if > 0) the notification badge pill
    /// using the exact same badge style as the menu bar icon.
    public static func makeMenuItemAttributedTitle(appName: String, badgeText: String?) -> NSAttributedString {
        let menuFont = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(
            string: appName,
            attributes: [.font: menuFont]
        )

        guard let badgeText, !badgeText.isEmpty else {
            return result
        }

        let badgeImage = makeBadgePillImage(text: badgeText)
        let attachment = NSTextAttachment()
        attachment.image = badgeImage
        let yOffset = (menuFont.capHeight - badgeImage.size.height) / 2
        attachment.bounds = NSRect(
            x: 0,
            y: yOffset,
            width: badgeImage.size.width,
            height: badgeImage.size.height
        )

        result.append(NSAttributedString(string: "  ", attributes: [.font: menuFont]))
        result.append(NSAttributedString(attachment: attachment))
        return result
    }
}
