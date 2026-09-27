import SwiftUI

/// The always-there toolbar control. One click arms or disarms; the chevron
/// opens the options. State lives in `KeepAwake`, never in the toolbar item,
/// because SwiftUI rebuilds toolbar items freely and would drop it.
///
/// Nothing in here animates on its own. A `repeatForever` pulse inside a
/// toolbar item re-laid out the whole toolbar on every frame, and on macOS 27
/// the glass behind the items visibly flickered with it.
struct KeepAwakeToolbarButton: View {
    @ObservedObject private var keepAwake = KeepAwake.shared

    private let idleChoices = [2, 5, 10, 15, 30, 60]

    var body: some View {
        Menu {
            Toggle("Keep the Mac awake while agents work", isOn: Binding(
                get: { keepAwake.isEnabled },
                set: { _ in keepAwake.toggle() }
            ))

            Divider()

            Text(statusLine)
            Text(keepAwake.networkOnline ? "Network online" : "Network offline · paused after 90 s")
            Text(lidLine)
            if let percent = keepAwake.batteryPercent {
                Text("Battery \(percent)% · \(keepAwake.onBattery ? "on battery" : "charging")")
            }
            if !keepAwake.isHolding, let release = keepAwake.lastAutoRelease {
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
            Toggle("Keep the screen on while agents work", isOn: $keepAwake.keepScreenOn)
            Toggle("Stay awake with the lid closed", isOn: $keepAwake.blockLidSleep)
            if keepAwake.blockLidSleep {
                Text("With the lid closed the screen goes dark and agents keep working; the Mac sleeps once they are done.")
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
        .help(helpText)
        .accessibilityLabel("Keep awake")
        .accessibilityValue(keepAwake.isEnabled ? (keepAwake.isHolding ? "Holding sleep" : "Armed") : "Off")
        .animation(Motion.state, value: keepAwake.isEnabled)
        .animation(Motion.state, value: keepAwake.isHolding)
        .animation(Motion.state, value: keepAwake.workingCount > 0)
    }

    private var pill: some View {
        HStack(spacing: 6) {
            ZStack {
                if keepAwake.isHolding {
                    Circle()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: 22, height: 22)
                        .transition(.opacity)
                }
                NucleoIconView(.coffee, size: 15)
                    .foregroundStyle(keepAwake.isEnabled ? Color.accentColor : Color.secondary)
            }
            .frame(width: 22, height: 22)

            if keepAwake.isHolding {
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
        .padding(.horizontal, keepAwake.isHolding ? 8 : 2)
        .frame(height: 26)
        .background {
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(keepAwake.isHolding ? 0.12 : 0))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(keepAwake.isHolding ? 0.28 : 0), lineWidth: 0.75)
        }
        .contentShape(Capsule())
    }

    private var helpText: String {
        guard keepAwake.isEnabled else {
            return "Click to keep the Mac awake whenever agents work; use the arrow for options."
        }
        return keepAwake.isHolding
            ? "Keeping the Mac awake while agents work. Click to turn off; use the arrow for options."
            : "Armed: the Mac stays awake as soon as an agent works. Click to turn off."
    }

    private var statusLine: String {
        guard keepAwake.isEnabled else { return "Off · the Mac sleeps as usual" }
        switch keepAwake.workingCount {
        case 0:
            guard keepAwake.isHolding else { return "Armed · waiting for an agent to work" }
            let idle = keepAwake.idleSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            let seconds = max(0, keepAwake.idleMinutes * 60 - idle)
            return "Agents idle · sleep allowed in \(seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s")"
        case 1: return "Awake · 1 agent working"
        default: return "Awake · \(keepAwake.workingCount) agents working"
        }
    }

    private var lidLine: String {
        if !keepAwake.blockLidSleep { return "Lid closed: the Mac sleeps" }
        if keepAwake.lidClosed, keepAwake.isHolding {
            return keepAwake.screenDimmed
                ? "Lid closed · screen dimmed, agents keep working"
                : "Lid closed · screen off, agents keep working"
        }
        if keepAwake.lidSleepBlocked { return "Lid closed: screen off, agents keep working" }
        if keepAwake.isHolding, !keepAwake.sudoRuleInstalled { return "Lid protection not granted" }
        return "Lid protection applied while agents work"
    }
}
