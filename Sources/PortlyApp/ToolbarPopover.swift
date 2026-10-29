import AppKit
import SwiftUI

/// Shows a popover under a toolbar button without touching the toolbar.
///
/// SwiftUI's `.popover` on a toolbar item flips a `@State` inside the item,
/// and on macOS 27 any state change in a toolbar item lays the whole bar out
/// again, which shows as a flash across the glass. Presenting an AppKit
/// popover from the button's action, anchored to the button's own view, leaves
/// the toolbar exactly as it was.
@MainActor
enum ToolbarPopover {
    private final class Presenter: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var id: String?
        var closedAt: (id: String, date: Date)?

        func popoverDidClose(_ notification: Notification) {
            // The old popover's close animation ends after the new one
            // opened: only the current one may clear the record.
            guard let closing = notification.object as? NSPopover, closing === popover else { return }
            if let id { closedAt = (id, Date()) }
            popover = nil
            id = nil
        }
    }

    private static let presenter = Presenter()

    /// Opens `content` under the toolbar button that was just clicked, or
    /// closes it when it is already open for the same `id`.
    static func toggle<Content: View>(id: String, @ViewBuilder content: () -> Content) {
        if let open = presenter.popover, open.isShown {
            open.performClose(nil)
            if presenter.id == id { return }
        }
        // A transient popover already closed on the mouse-down of this very
        // click; reopening it would turn a toggle into a flicker.
        if let closed = presenter.closedAt, closed.id == id, Date().timeIntervalSince(closed.date) < 0.4 {
            presenter.closedAt = nil
            return
        }
        guard let anchor = anchor() else { return }
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = presenter
        presenter.popover = popover
        presenter.id = id
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .minY)
    }

    static func dismiss() {
        presenter.popover?.performClose(nil)
    }

    /// The toolbar item under the pointer, found from the click that fired
    /// the action. Falls back to the top-right corner of the window for a
    /// keyboard activation.
    private static func anchor() -> (view: NSView, rect: NSRect)? {
        guard let event = NSApp.currentEvent, let window = event.window ?? NSApp.keyWindow,
              let content = window.contentView else { return nil }
        let frame = content.superview ?? content
        if event.type == .leftMouseUp || event.type == .leftMouseDown {
            let point = frame.convert(event.locationInWindow, from: nil)
            if var hit = frame.hitTest(point), hit !== frame {
                var node: NSView? = hit
                while let current = node {
                    let name = String(describing: type(of: current))
                    if name.contains("ToolbarItemViewer") {
                        hit = current
                        break
                    }
                    node = current.superview
                }
                return (hit, hit.bounds)
            }
        }
        let rect = NSRect(x: content.bounds.maxX - 48, y: content.bounds.maxY - 1, width: 40, height: 1)
        return (content, rect)
    }
}
