import SwiftUI

/// The always-there toolbar control. One click toggles; the chevron opens the
/// options. State lives in `KeepAwake`, never in the toolbar item, because
/// SwiftUI rebuilds toolbar items freely and would drop it.
struct KeepAwakeToolbarButton: View {
    @ObservedObject private var keepAwake = KeepAwake.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private let idleChoices = [2, 5, 10, 15, 30, 60]

    var body: some View {
        Menu {
            Toggle("Keep the Mac awake while agents work", isOn: Binding(
                get: { keepAwake.isActive },
                set: { _ in keepAwake.toggle() }
            ))

            Divider()

            Text(workingLine)
            Text(keepAwake.networkOnline ? "Network online" : "Network offline · released after 90 s")
            Text(lidLine)
            if let percent = keepAwake.batteryPercent {
                Text("Battery \(percent)% · \(keepAwake.onBattery ? "on battery" : "charging")")
            }
            if let release = keepAwake.lastAutoRelease {
                Text("Last release: \(release.reason.message) at \(release.date.formatted(date: .omitted, time: .shortened))")
            }
            if let error = keepAwake.lastError {
                Text("⚠︎ \(error)")
            }

            Divider()

            Picker("Sleep after inactivity", selection: $keepAwake.idleMinutes) {
                ForEach(idleChoices, id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            Toggle("Block sleep with the lid closed", isOn: $keepAwake.blockLidSleep)
            if keepAwake.blockLidSleep {
                Text(keepAwake.sudoRuleInstalled
                    ? "Administrator rule installed, no password needed"
                    : "Asks for your password once, the first time it turns on")
            }
        } label: {
            pill
        } primaryAction: {
            keepAwake.toggle()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .help(keepAwake.isActive
            ? "Keeping the Mac awake while agents work. Click to stop; use the arrow for options."
            : "Click to keep the Mac awake while agents work; use the arrow for options.")
        .accessibilityLabel("Keep awake")
        .accessibilityValue(keepAwake.isActive ? "On" : "Off")
        .animation(Motion.state, value: keepAwake.isActive)
        .animation(Motion.state, value: keepAwake.workingCount > 0)
        .onAppear { syncBreathing() }
        .onChange(of: keepAwake.isActive) { syncBreathing() }
    }

    private var pill: some View {
        HStack(spacing: 6) {
            ZStack {
                if keepAwake.isActive {
                    Circle()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: 22, height: 22)
                        .scaleEffect(breathing && !reduceMotion ? 1.25 : 1)
                        .opacity(breathing ? 0.45 : 1)
                        .transition(.opacity)
                }
                NucleoIconView(.coffee, size: 15)
                    .foregroundStyle(keepAwake.isActive ? Color.accentColor : Color.secondary)
            }
            .frame(width: 22, height: 22)

            if keepAwake.isActive {
                Text(keepAwake.workingCount > 0 ? "Awake · working" : "Awake")
                    .font(PortlyTypography.label)
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if keepAwake.lastError != nil {
                NucleoIconView(.warning, size: 11)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
                    .accessibilityLabel("Keep awake reported a problem")
            }
        }
        .padding(.horizontal, keepAwake.isActive ? 8 : 2)
        .frame(height: 26)
        .background {
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(keepAwake.isActive ? 0.12 : 0))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(keepAwake.isActive ? 0.28 : 0), lineWidth: 0.75)
        }
        .contentShape(Capsule())
    }

    private var workingLine: String {
        switch keepAwake.workingCount {
        case 0:
            if keepAwake.isActive {
                let seconds = max(0, keepAwake.idleMinutes * 60 - keepAwake.idleSeconds)
                return "No agent working · sleep allowed in \(seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s")"
            }
            return "No agent working"
        case 1: return "1 terminal working"
        default: return "\(keepAwake.workingCount) terminals working"
        }
    }

    private var lidLine: String {
        if !keepAwake.blockLidSleep { return "Lid closed: the Mac sleeps" }
        if keepAwake.lidSleepBlocked { return "Lid closed: stays awake" }
        return keepAwake.isActive ? "Lid protection not granted" : "Lid protection applied when turned on"
    }

    private func syncBreathing() {
        if keepAwake.isActive {
            withAnimation(Motion.pulse) { breathing = true }
        } else {
            withAnimation(Motion.state) { breathing = false }
        }
    }
}
