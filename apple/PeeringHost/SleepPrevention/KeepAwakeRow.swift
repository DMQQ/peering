import Foundation
import RemoteCore
import SwiftUI

/// The row for "keep this Mac awake": one power assertion, held for as long as the host runs.
struct KeepAwakeRow: View {
    @Environment(HostModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.preventLidCloseSleep ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Keep Mac awake")
                    .font(.subheadline.weight(.medium))
                // Says which of the two switches this is, because the second one is about the same
                // subject and costs something: this holds an idle-sleep assertion, which needs no
                // permission and is released when Peering quits, and it does not keep a closed Mac
                // running. The row below does.
                Text("Keeps this Mac awake on its own: no idle sleep, no display sleep, and no permission prompt. It does not survive the lid being shut, and the row about the lid is the one that does. Lifted automatically when Peering quits.")
                    .hostCaption()

                // **The line that says the switch is on and nothing is happening.** Without it the
                // only way to find out whether this Mac is being held was to guess, which is what a
                // switch reading "on" over a sleeping Mac invites. See
                // ``HostModel/keepAwakeWithheldExplanation``.
                if let withheld = model.keepAwakeWithheldExplanation {
                    Text(withheld)
                        .font(.caption)
                        .foregroundStyle(HostPalette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { model.preventLidCloseSleep },
                set: { model.setPreventLidCloseSleep($0) }
            ))
            .hostSwitch()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
