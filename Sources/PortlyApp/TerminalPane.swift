import AppKit
import SwiftUI
import SwiftTerm

/// The terminal's colours, in one place.
///
/// SwiftTerm paints its own background rather than setting `layer.backgroundColor`,
/// so the chrome around it cannot discover the colour by reading the view — it has
/// to be told. Both the terminal and its surrounding surface read from here so the
/// padding around the text is genuinely the same black as the text sits on.
enum TerminalTheme {
    static let background = NSColor(srgbRed: 0.043, green: 0.051, blue: 0.071, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.84, green: 0.86, blue: 0.9, alpha: 1)

    /// A deliberate hairline, a few steps lighter than the surface. Fixed rather
    /// than semantic: it has to sit on the terminal's own black in both
    /// appearances, not on the window's.
    static let border = NSColor(srgbRed: 0.2, green: 0.23, blue: 0.29, alpha: 1)

    static let surfaceInset: CGFloat = 10
    static let textInset: CGFloat = 12
    static let cornerRadius: CGFloat = 10
}

/// Holds a terminal view and resizes it only once its own size has settled.
///
/// Every frame of a sidebar slide, a divider drag or a window resize used to
/// reach the terminal: SwiftTerm reflowed its buffer, told the PTY, and the
/// agent redrew its whole screen, all before the next frame was due. Dozens of
/// reflows in a quarter second is what the animation stuttered on. Now the
/// terminal keeps its size while the host moves, pinned to the top-left corner
/// and clipped, and reflows once, when the host has been still for a moment —
/// the way iTerm lets its text sit while the window is dragged.
final class DeferredResizeHost: NSView {
    static let settleDelay: TimeInterval = 0.08

    private weak var content: NSView?
    private var pending: DispatchWorkItem?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = TerminalTheme.background.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    var contentView: NSView? { content }

    func embed(_ view: NSView) {
        guard content !== view else { return }
        content?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        view.frame = CGRect(origin: .zero, size: bounds.size)
        addSubview(view)
        content = view
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let content, content.frame.size != bounds.size else { return }
        // A view that has no size yet is not mid-animation: give it one now.
        if content.frame.size == .zero {
            settle()
            return
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        settle()
    }

    private func settle() {
        pending?.cancel()
        pending = nil
        guard let content else { return }
        let target = CGRect(origin: .zero, size: bounds.size)
        guard content.frame != target else { return }
        content.frame = target
    }
}

/// Hosts the server's live terminal. The view itself is owned by the runtime, so
/// scrollback and keyboard focus survive switching servers or closing the window.
struct TerminalPane: NSViewRepresentable {
    let runtime: ServerRuntime

    func makeNSView(context: Context) -> NSView {
        let container = ContainerView()
        container.embed(runtime.terminalView())
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? ContainerView else { return }
        container.embed(runtime.terminalView())
    }

    /// A plain container so swapping servers is a view swap, not a rebuild.
    final class ContainerView: NSView {
        private let surface = NSView()
        private let host = DeferredResizeHost()
        private weak var current: NSView?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configureSurface()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureSurface()
        }

        private func configureSurface() {
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.wantsLayer = true
            surface.layer?.cornerRadius = TerminalTheme.cornerRadius
            surface.layer?.cornerCurve = .continuous
            surface.layer?.masksToBounds = true
            surface.layer?.backgroundColor = TerminalTheme.background.cgColor
            surface.layer?.borderWidth = 1
            surface.layer?.borderColor = TerminalTheme.border.cgColor
            addSubview(surface)

            let inset = TerminalTheme.surfaceInset
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                surface.topAnchor.constraint(equalTo: topAnchor, constant: inset),
                surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            ])

            host.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(host)
            let text = TerminalTheme.textInset
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: text),
                host.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -text),
                host.topAnchor.constraint(equalTo: surface.topAnchor, constant: text),
                host.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -text),
            ])
        }

        func embed(_ view: NSView) {
            guard current !== view else { return }
            view.wantsLayer = true
            view.layer?.cornerRadius = 0
            // Belt and braces: SwiftTerm draws this colour, but setting the layer
            // too means a live resize never flashes the window colour through.
            view.layer?.backgroundColor = TerminalTheme.background.cgColor
            host.embed(view)
            current = view
            window?.makeFirstResponder(view)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let current { window?.makeFirstResponder(current) }
        }
    }
}
