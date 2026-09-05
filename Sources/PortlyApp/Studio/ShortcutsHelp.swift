import SwiftUI

/// The shortcut cheat sheet behind the ⓘ button: three short groups, keycaps
/// drawn like the keyboard, nothing else.
struct ShortcutsHelpPopover: View {
    private struct Row {
        let title: String
        let keys: [String]
    }

    private struct Group {
        let title: String
        let rows: [Row]
    }

    private let groups: [Group] = [
        Group(title: "Terminals", rows: [
            Row(title: "New coding session", keys: ["⌘", "N"]),
            Row(title: "Split right", keys: ["⌘", "D"]),
            Row(title: "Split down", keys: ["⇧", "⌘", "D"]),
            Row(title: "New shell terminal", keys: ["⌘", "T"]),
            Row(title: "New agent terminal", keys: ["⇧", "⌘", "T"]),
            Row(title: "Close terminal", keys: ["⌘", "W"]),
        ]),
        Group(title: "Focus & view", rows: [
            Row(title: "Zoom the terminal", keys: ["⇧", "⌘", "↩"]),
            Row(title: "Next / previous terminal", keys: ["⌘", "]", "·", "⌘", "["]),
            Row(title: "Bigger / smaller text", keys: ["⌘", "+", "·", "⌘", "−"]),
            Row(title: "Default text size", keys: ["⌘", "0"]),
            Row(title: "Clear terminal", keys: ["⌘", "K"]),
        ]),
        Group(title: "Panels", rows: [
            Row(title: "Quick terminal", keys: ["⌘", "J"]),
            Row(title: "Environment files", keys: ["⇧", "⌘", "E"]),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                NucleoIconView(.keyboard, size: 14)
                    .foregroundStyle(Color.accentColor)
                Text("Keyboard shortcuts")
                    .font(PortlyTypography.bodyMedium)
            }

            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title.uppercased())
                        .font(PortlyTypography.label)
                        .foregroundStyle(.tertiary)
                        .kerning(0.6)
                    ForEach(group.rows, id: \.title) { row in
                        HStack(spacing: 10) {
                            Text(row.title)
                                .font(PortlyTypography.body)
                            Spacer(minLength: 16)
                            HStack(spacing: 3) {
                                ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in
                                    if key == "·" {
                                        Text("or")
                                            .font(PortlyTypography.metadata)
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 2)
                                    } else {
                                        KeyCap(key)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Text("Drop files anywhere on a project to copy them to its root.")
                .font(PortlyTypography.metadata)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 330)
    }
}

/// A key drawn as a keycap: light face, hairline edge, a shadow that reads as
/// the key's thickness.
struct KeyCap: View {
    let label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .frame(minWidth: 22)
            .padding(.horizontal, 5)
            .frame(height: 22)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1))
            }
            .accessibilityLabel(label)
    }
}
