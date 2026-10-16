import AppKit
import ObjectiveC

/// How the sidebar opens and closes.
///
/// `NavigationSplitView` collapses its sidebar with AppKit's stock animation,
/// which is neither quick nor shaped: it reads as a slide that simply stops.
/// Portly's sidebar snaps instead — fast, accelerating out of the gate and
/// settling softly at the end, the same cadence as the rest of its motion.
///
/// The toolbar button and ⌃⌘S both reach the split view controller through
/// `toggleSidebar(_:)`, which SwiftUI's controller inherits unchanged, so that
/// one method is swapped once at launch for a version that collapses the same
/// sidebar item inside an animation group of Portly's own. If a future SwiftUI
/// stops exposing the sidebar as a split view item, the swap hands the call
/// straight back to AppKit and nothing is lost but the curve.
enum SidebarMotion {
    static let duration: TimeInterval = 0.24
    /// Ease in, then out, with the brake applied at the very end.
    static let timing = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.12, 1)

    private static var installed = false

    static func install() {
        guard !installed,
              let original = class_getInstanceMethod(
                  NSSplitViewController.self, #selector(NSSplitViewController.toggleSidebar(_:))
              ),
              let replacement = class_getInstanceMethod(
                  NSSplitViewController.self, #selector(NSSplitViewController.portlyToggleSidebar(_:))
              )
        else { return }
        method_exchangeImplementations(original, replacement)
        installed = true
    }
}

extension NSSplitViewController {
    /// Swapped with `toggleSidebar(_:)`; calling it by its own name from here
    /// therefore runs AppKit's original implementation.
    @objc fileprivate func portlyToggleSidebar(_ sender: Any?) {
        guard let sidebar = splitViewItems.first(where: { $0.behavior == .sidebar }) else {
            portlyToggleSidebar(sender)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SidebarMotion.duration
            context.timingFunction = SidebarMotion.timing
            context.allowsImplicitAnimation = true
            sidebar.animator().isCollapsed.toggle()
        }
    }
}
