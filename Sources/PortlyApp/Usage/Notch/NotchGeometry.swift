import AppKit

extension NSScreen: ScreenDescribing {
    var frameValue: CGRect { frame }
    var visibleFrameValue: CGRect { visibleFrame }

    /// Measured from the two menu-bar strips *either side* of the notch, which
    /// is the only thing AppKit describes directly. A display without a notch
    /// reports no auxiliary areas.
    var hardwareNotch: HardwareNotch? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return nil
        }
        let width = frame.width - left.width - right.width
        let height = safeAreaInsets.top
        guard width > 0, height > 0 else { return nil }
        return HardwareNotch(width: width, height: height)
    }
}

enum NotchGeometry {
    /// The panel hugs the chosen edge and is centred along it.
    ///
    /// Which edge it hugs is `visibleFrame`'s, so a bottom notch rests on top
    /// of the Dock and moves when the Dock hides. Centring stays on `frame`,
    /// so a Dock at the bottom never shifts a right-edge notch up and down.
    ///
    /// The rect is rounded out to whole points: AppKit rounds window frames
    /// anyway, and a hairline of wallpaper along the edge is all it takes for
    /// the notch to read as floating rather than welded to the bezel.
    static func panelFrame(
        for screen: ScreenDescribing,
        panelSize: CGSize,
        edge: NotchEdge = .right
    ) -> CGRect {
        let full = screen.frameValue
        let usable = screen.visibleFrameValue
        let width = panelSize.width.rounded(.up)
        let height = panelSize.height.rounded(.up)

        let origin: CGPoint
        switch edge {
        case .right:
            origin = CGPoint(x: usable.maxX - width, y: full.midY - height / 2)
        case .left:
            origin = CGPoint(x: usable.minX, y: full.midY - height / 2)
        case .top:
            // On a Mac with a notch of its own, this one goes all the way up to
            // meet it, past the menu bar, so the two read as a single shape.
            let top = screen.hardwareNotch == nil ? usable.maxY : full.maxY
            origin = CGPoint(x: full.midX - width / 2, y: top - height)
        case .bottom:
            origin = CGPoint(x: full.midX - width / 2, y: usable.minY)
        }

        return CGRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: width,
            height: height
        )
    }

    /// The notch follows the screen with the menu bar.
    static func preferredScreen(from screens: [NSScreen]) -> NSScreen? {
        NSScreen.main ?? screens.first
    }
}
