import PortlyCore
import SwiftUI

/// Browse and search the whole Nucleo set, in French or English. The grid is
/// lazy so 3 400 glyphs cost nothing until they scroll into view.
struct IconPicker: View {
    @Binding var selection: String
    let tint: Color

    @State private var query = ""
    @State private var category: String?
    @State private var results: [NucleoIcon] = []
    @State private var hovered: String?
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 4), count: 11)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                searchField
                categoryMenu
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(results) { icon in
                            cell(icon)
                                .id(icon.id)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 236)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07))
                }
                .overlay {
                    if results.isEmpty {
                        VStack(spacing: 6) {
                            NucleoIconView(.search, size: 20)
                                .foregroundStyle(.tertiary)
                            Text("No icon matches “\(query)”")
                                .font(PortlyTypography.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onAppear {
                    refresh()
                    proxy.scrollTo(selection, anchor: .center)
                }
                .onChange(of: query) { refresh() }
                .onChange(of: category) { refresh() }
            }

        }
        .padding(.vertical, 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            NucleoIconView(.search, size: 12)
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search icons")
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    NucleoIconView(.xmarkCircle, size: 12)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button("All categories") { category = nil }
            Divider()
            ForEach(IconCatalog.shared.categories, id: \.self) { name in
                Button(name.replacingOccurrences(of: "-", with: " ").capitalized) {
                    category = name
                }
            }
        } label: {
            HStack(spacing: 5) {
                NucleoIconView(.grid, size: 11)
                Text(category?.replacingOccurrences(of: "-", with: " ").capitalized ?? "All")
                    .lineLimit(1)
            }
            .font(PortlyTypography.body)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(height: 28)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .help("Filter by category")
    }

    private func cell(_ icon: NucleoIcon) -> some View {
        let isSelected = selection == icon.id
        return Button {
            selection = icon.id
        } label: {
            NucleoIconView(icon.id, size: 16)
                .foregroundStyle(isSelected ? tint : Color.secondary)
                .frame(width: 34, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(cellBackground(icon.id, selected: isSelected))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? tint.opacity(0.35) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon.displayName)
        .accessibilityLabel(icon.displayName)
        .accessibilityValue(isSelected ? "Selected" : "")
        .onHover { hovering in
            hovered = hovering ? icon.id : nil
        }
    }

    private func cellBackground(_ id: String, selected: Bool) -> Color {
        if selected { return tint.opacity(0.14) }
        if hovered == id { return Color.primary.opacity(0.07) }
        return .clear
    }

    private func refresh() {
        results = IconCatalog.shared.search(query, category: category, limit: 800)
    }
}
