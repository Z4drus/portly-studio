import SwiftUI

// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz.

/// Every number in the notch is measured off Codenotch's design frame
/// (2000 x 2000 px), so the layout is proportionally exact rather than
/// eyeballed. One anchor picks the scale: the provider ring is 44pt across,
/// and it measures 117px in the frame.
enum NotchDesign {
    /// Points per pixel of the design frame.
    static let scale: CGFloat = 44.0 / 117.0

    /// A distance measured in design-frame pixels, in points.
    static func px(_ pixels: CGFloat) -> CGFloat { pixels * scale }

    /// Cap-height fraction of an em for SF Pro. Text in the frame can only be
    /// measured by its cap height, so this converts back to a point size.
    private static let capRatio: CGFloat = 0.714

    /// The point size whose capital letters are `pixels` tall in the frame.
    static func fontSize(capPixels pixels: CGFloat) -> CGFloat {
        px(pixels) / capRatio
    }
}

/// Sampled from the design frame, not invented. The notch is pure black on
/// every appearance: it reads as part of the bezel, not as a window.
enum NotchPalette {
    static let notch = Color.black
    static let card = Color.black
    static let ringTrack = Color(hex: 0x303030)
    static let barTrack = Color(hex: 0x2D2D2D)

    static let ample = Color(hex: 0x00FF88)
    static let watch = Color(hex: 0xF2FF00)
    static let critical = Color(hex: 0xFF3F00)

    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0x808080)
}

/// Sizes derived from cap heights measured in the design frame, so they track
/// `NotchDesign.scale` along with everything else.
enum NotchTypography {
    /// The percent under each provider ring. Cap height 27px in the frame.
    static let percent = Font.system(size: NotchDesign.fontSize(capPixels: 27), weight: .semibold)

    /// "Claude Usage". Cap height 26px.
    static let cardTitle = Font.system(size: NotchDesign.fontSize(capPixels: 26), weight: .semibold)

    /// "Current session", "73% Used", "Resets in 51 min". Cap height 18px.
    static let cardBody = Font.system(size: NotchDesign.fontSize(capPixels: 18), weight: .regular)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
