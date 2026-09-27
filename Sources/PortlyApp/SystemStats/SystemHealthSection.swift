import SwiftUI

/// The "This Mac" section at the top of the Resources view: Mac-wide CPU,
/// memory, GPU, network, disk, temperatures and power as live chart cards.
///
/// It owns its model, so nothing is sampled until the section appears, and
/// sampling pauses whenever the section leaves the screen or its window is
/// hidden, minimized or fully covered.
struct SystemHealthSection: View {
    @StateObject private var model = SystemStatsModel()
    @State private var isPresented = false
    @State private var isWindowVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.cards.isEmpty {
                SystemCardPlaceholder(height: 240)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                SystemCardGridLayout(minimumCardWidth: 340, spacing: 12) {
                    ForEach(model.cards, id: \.self) { kind in
                        card(kind)
                    }
                }
            }
        }
        .background {
            WindowVisibilityObserver { visible in
                isWindowVisible = visible
            }
        }
        .onAppear {
            isPresented = true
            updateSampling()
        }
        .onDisappear {
            isPresented = false
            updateSampling()
        }
        .onChange(of: isWindowVisible) {
            updateSampling()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("This Mac")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text(summaryText)
                    .font(PortlyTypography.metadata)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            LiveBadge(text: "Live · 1 s", accessibilityText: "Live data, updated every second")
        }
    }

    private var summaryText: String {
        guard let summary = model.summary else { return "Whole-machine health, updated every second" }
        return [
            summary.chipName,
            summary.coreSummary,
            SystemStatsFormat.memory(summary.memoryBytes) + " memory",
            summary.osVersion,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    @ViewBuilder
    private func card(_ kind: SystemCardKind) -> some View {
        switch kind {
        case .cpu:
            CPUStatCard(feed: model.cpu)
        case .memory:
            MemoryStatCard(feed: model.memory)
        case .gpu:
            GPUStatCard(feed: model.gpu)
        case .network:
            NetworkStatCard(feed: model.network)
        case .disk:
            DiskStatCard(feed: model.disk)
        case .thermals:
            ThermalStatCard(feed: model.thermals)
        case .power:
            PowerStatCard(feed: model.power, showsThermalState: !model.cards.contains(.thermals))
        }
    }

    private func updateSampling() {
        if isPresented, isWindowVisible {
            model.start()
        } else {
            model.stop()
        }
    }
}

/// The green "Live" capsule used by the dashboard's section headers.
struct LiveBadge: View {
    let text: String
    let accessibilityText: String

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
        } icon: {
            NucleoIconView(.signal, size: 14)
                .foregroundStyle(.green)
        }
        .font(PortlyTypography.bodyMedium)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.green.opacity(0.1), in: Capsule())
        .overlay {
            Capsule().strokeBorder(.green.opacity(0.2), lineWidth: 0.75)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
