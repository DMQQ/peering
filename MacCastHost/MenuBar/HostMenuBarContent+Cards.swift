import AppKit
import MacCastKit
import RemoteCore
import SwiftUI

extension HostMenuBarContent {
    func updateRow(_ version: String) -> some View {
        Button { updater.install() } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text("Version \(version)")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                Text(updater.readyToInstall ? "Restart" : "Install")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor, in: Capsule())
            }
            .padding(10)
            .background(
                Color.accentColor.opacity(0.14),
                in: RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.4))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!updater.canCheck)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    var setupCard: some View {
        card {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.orange)
                Text("Peering needs Screen Recording and Accessibility before a phone can connect.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var devicesCard: some View {
        card(title: String(localized: "Connected")) {
            // A timeline rather than a formatted string, so the timers run while the panel is open.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 8) {
                    ForEach(model.connectedClients) { client in
                        HStack(spacing: 9) {
                            Image(systemName: "iphone")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.primary)
                                .frame(width: 26, height: 26)
                                .background(Color.primary.opacity(0.08), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(client.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.primary)
                                        .lineLimit(1)
                                    pathBadge(for: client)
                                }
                                Text(usageEstimate)
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                                    .contentTransition(.numericText())
                            }
                            Spacer(minLength: 0)
                            Text(client.elapsedDescription(now: context.date))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func pathBadge(for client: ConnectedClient) -> some View {
        let label = !client.viaRelay ? "LAN" : model.directPathOpen ? "P2P" : "RELAY"
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18)))
            .help(!client.viaRelay ? "On this network" : model.directPathOpen
                ? "Over the internet, straight to the device" : "Over the internet, through the relay")
    }

    /// The host's own cost shared evenly across the attached devices, which is an estimate:
    /// capture and encoding are one pipeline, not one per device.
    private var usageEstimate: String {
        guard let rates = model.resources.rates else { return "Measuring…" }
        let share = Double(max(1, model.connectedClients.count))
        let cpu = HostResourceSampler.percent(rates.cpuOfMachine / share)
        return String(localized: "≈ \(cpu) CPU · \(HostResourceSampler.networkText(rates.bytesPerSecond / share))")
    }

    var awakeCard: some View {
        card(title: String(localized: "Staying awake")) {
            VStack(spacing: 10) {
                switchRow(
                    String(localized: "Keep Mac reachable"),
                    symbol: "wifi",
                    isOn: Binding(
                        get: { model.preventLidCloseSleep },
                        set: { model.setPreventLidCloseSleep($0) }
                    ),
                    note: model.keepAwakeWithheld ? String(localized: "Not being held: this Mac sleeps on its own") : nil
                )

                lidCloseRow

                if model.asksToReleaseKeepAwake {
                    Button {
                        Task { await model.releaseKeepAwakeNow() }
                    } label: {
                        Text("Nobody is connected: let this Mac sleep")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }

                Divider().overlay(Color.primary.opacity(0.12))

                awakeHoursRow
            }
        }
    }

    @ViewBuilder
    private var lidCloseRow: some View {
        if model.lidCloseRuleInstalled == true {
            let notInForce = model.keepRunningWithLidClosed && !model.keepAwakeWithheld
                && model.lidCloseSystemState == .off
            switchRow(
                "Run with the lid closed",
                symbol: "laptopcomputer",
                isOn: Binding(
                    get: { model.keepRunningWithLidClosed },
                    set: { wanted in Task { await model.setKeepRunningWithLidClosed(wanted) } }
                ),
                note: notInForce ? String(localized: "Not in force: this Mac still sleeps on a closed lid") : nil
            )
            .disabled(model.lidCloseBusy)
        } else {
            Button { openMainWindow() } label: {
                HStack(spacing: 9) {
                    rowIcon("laptopcomputer")
                    Text("Run with the lid closed")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                    Text("Set up")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
    }

    private var awakeHoursRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            switchRow(
                String(localized: "Only during set hours"),
                symbol: "clock",
                isOn: Binding(
                    get: { model.keepAwakeScheduleEnabled },
                    set: { model.setKeepAwakeSchedule(enabled: $0) }
                ),
                note: nil
            )

            if model.keepAwakeScheduleEnabled {
                HStack(spacing: 6) {
                    hourPicker(
                        get: { model.keepAwakeStartHour },
                        set: { model.setKeepAwakeHours(start: $0, end: model.keepAwakeEndHour) }
                    )
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                    hourPicker(
                        get: { model.keepAwakeEndHour },
                        set: { model.setKeepAwakeHours(start: model.keepAwakeStartHour, end: $0) }
                    )
                    Spacer(minLength: 0)
                    if model.keepAwakeEndHour < model.keepAwakeStartHour {
                        Text("Overnight")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(.leading, 35)
                .transition(.opacity)
            }
        }
        .animation(HostMotion.state, value: model.keepAwakeScheduleEnabled)
    }

    private func hourPicker(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(0..<24, id: \.self) { hour in
                Button(String(format: "%02d:00", hour)) { set(hour) }
            }
        } label: {
            Text(String(format: "%02d:00", get()))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }

    var resourcesRow: some View {
        let rates = model.resources.rates
        let memory = model.resources.memoryBytes
        return HStack(spacing: 8) {
            reading("CPU", rates.map(HostResourceSampler.cpuPercent) ?? "…")
            reading(String(localized: "Memory"), memory > 0 ? HostResourceSampler.memoryText(memory) : "…")
            reading(String(localized: "Sent"), rates.map { HostResourceSampler.networkText($0.bytesPerSecond) } ?? "…")
        }
    }

    private func reading(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }
}
