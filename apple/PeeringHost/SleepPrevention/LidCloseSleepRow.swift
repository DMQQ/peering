import Foundation
import RemoteCore
import SwiftUI

/// The row for "keep running with the lid closed", and the explanation it owes before it does
/// anything.
struct LidCloseSleepRow: View {
    @Environment(HostModel.self) private var model
    @State private var explaining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(model.keepRunningWithLidClosed ? HostPalette.ink : HostPalette.muted)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep running with the lid closed")
                        .font(.subheadline.weight(.medium))
                    Text("Survives the lid being shut, which the switch above does not. macOS only offers this through pmset, so it needs your administrator password once, and while it is on the Mac does not sleep at all: leave it open to the air rather than shut in a bag. Undone when Peering quits, and repaired at the next launch if it is force quit instead.")
                        .hostCaption()
                }

                Spacer(minLength: 12)

                // A spinner in place of the switch while the password dialog is up, because the
                // switch cannot move until there is an answer and a control that ignores a click
                // reads as broken.
                if model.lidCloseBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26)
                } else {
                    Toggle("", isOn: Binding(get: { model.keepRunningWithLidClosed }, set: apply))
                        .hostSwitch()
                }
            }

            if let failure = model.lidCloseFailure {
                Text(failure)
                    .hostCaption(HostPalette.danger)
                    .padding(.leading, 38)
            }

            // **The switch and the machine, when they disagree.** This is the state the entire
            // recovery path exists for and it used to be invisible: a rule removed by hand, or a
            // crash between the write and the marker, left a switch reading "on" over a Mac that
            // slept the moment the lid shut. The app cannot promise a Mac stays up; it can promise
            if model.keepRunningWithLidClosed, !model.keepAwakeWithheld,
               model.lidCloseSystemState == .off {
                Text("Switched on, but this Mac is not doing it: pmset reports the setting as off. Switch this off and on again to put it back.")
                    .hostCaption(HostPalette.danger)
                    .padding(.leading, 38)
            }

            if model.lidCloseRuleInstalled == true {
                HStack(spacing: 6) {
                    Text("The administrator rule covers only \(LidCloseSleep.command(disabled: true)) and \(LidCloseSleep.command(disabled: false)).")
                        .hostCaption()

                    Button {
                        Task { await model.removeLidCloseRule() }
                    } label: {
                        Text("Remove it").underline()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .help("Deletes /etc/sudoers.d/peering-sleep and lets this Mac sleep normally again, in one administrator prompt.")
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .alert("Keep running with the lid closed?", isPresented: $explaining) {
            Button("Install the rule") { Task { await model.enableLidCloseSleep() } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(explanation)
        }
        .task { await model.checkLidCloseSleepRule() }
    }

    /// The price, before anything is asked for.
    private var explanation: String {
        String(localized: """
        macOS keeps a Mac awake with its lid shut only through pmset, and that needs administrator \
        rights. Peering will ask for your password once and leave a rule at \
        /etc/sudoers.d/peering-sleep.

        The rule allows exactly two commands, run as root: \(LidCloseSleep.command(disabled: true)) \
        and \(LidCloseSleep.command(disabled: false)). Nothing else becomes possible, and removing \
        the rule takes it all back.

        While it is on, the Mac does not sleep at all, on battery included, so leave it open to the \
        air rather than shut in a bag. Peering turns it back off when it quits and when you switch \
        this off.
        """)
    }

    /// The switch asks first or acts, depending on whether the price has been paid before.
    private func apply(_ wanted: Bool) {
        if wanted, model.lidCloseRuleInstalled != true {
            explaining = true
        } else {
            Task { await model.setKeepRunningWithLidClosed(wanted) }
        }
    }
}
