import AppKit
import SwiftUI

/// Brand imagery shared by the views, so no view falls back to a generic
/// SF Symbol where the app's own identity belongs.
enum BrandAssets {
    /// Menu bar status item glyph: the logo's monitor with its resize marks
    /// knocked out, as a template image so macOS tints it for light and dark
    /// menu bars. Multi-resolution TIFF (18 px and 36 px representations)
    /// generated from `branding/menubar-icon.svg`; NSImage picks the rep that
    /// matches the screen's scale.
    static let menuBarIcon: NSImage = {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "tiff"),
              let image = NSImage(contentsOf: url) else {
            // Never ship a blank status item: fall back to the closest system glyph.
            return NSImage(systemSymbolName: "display", accessibilityDescription: "SimpleDisplay")!
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    /// The real app icon (AppIcon.icns from the bundle), as rendered by macOS.
    static var appIcon: NSImage { NSApp.applicationIconImage }
}

/// The app icon at a given point size, for headers and about cards.
struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: BrandAssets.appIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
