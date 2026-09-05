import PortlyCore
import SwiftUI

/// The project's scratch shell, floating over the detail area. One per
/// project, alive for the whole app session, reachable from any screen with
/// ⌘J. For the quick `pnpm add` while the agents keep working.
struct QuickTerminalOverlay: View {
    let project: Project

    @ObservedObject private var workspace = StudioWorkspace.shared
    @State private var size: CGSize = .zero
    @State private var dragStartSize: CGSize?

    private let minimumSize = CGSize(width: 380, height: 220)

    var body: some View {
        let runtime = workspace.quickTerminal(for: project)
        return VStack(spacing: 0) {
            header(runtime)
            StudioTerminalHost(runtime: runtime, inset: 10)
        }
        .frame(
            width: max(size.width, minimumSize.width),
            height: max(size.height, minimumSize.height)
        )
        .background(Color(nsColor: TerminalTheme.background))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: TerminalTheme.border))
        }
        .overlay(alignment: .bottomLeading) { resizeHandle }
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .onAppear {
            size = workspace.config.quickTerminalSize
            DispatchQueue.main.async { runtime.focus() }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func header(_ runtime: TerminalPaneRuntime) -> some View {
        HStack(spacing: 8) {
            NucleoIconView(.terminalSquare, size: 12)
                .foregroundStyle(Color.accentColor)
            Text("Quick terminal")
                .font(PortlyTypography.bodyMedium)
                .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.9))
            Text(project.name)
                .font(PortlyTypography.metadata)
                .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.5))
                .lineLimit(1)
            Spacer()
            headerButton(.broom, help: "Clear") { runtime.clear() }
            if !runtime.isRunning {
                headerButton(.restart, help: "New shell") { runtime.restart() }
            }
            headerButton(.xmark, help: "Hide (⌘J)") {
                workspace.quickTerminalVisible = false
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(Color.white.opacity(0.05))
    }

    private func headerButton(_ icon: AppIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NucleoIconView(icon, size: 11)
                .foregroundStyle(Color(nsColor: TerminalTheme.foreground).opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Bottom-left corner grip: the panel is pinned top-right, so growing it
    /// means pulling this corner away.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartSize == nil { dragStartSize = size }
                        guard let start = dragStartSize else { return }
                        size = CGSize(
                            width: max(minimumSize.width, start.width - value.translation.width),
                            height: max(minimumSize.height, start.height + value.translation.height)
                        )
                    }
                    .onEnded { _ in
                        dragStartSize = nil
                        workspace.setQuickTerminalSize(size)
                    }
            )
            .accessibilityLabel("Resize quick terminal")
    }
}
