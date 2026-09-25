import SwiftUI

/// Second onboarding step, shown once both permissions are granted: the switches for reaching
/// this Mac while it is closed or unattended. Skippable, since every one of them defaults off.
struct AwaySwitchesOnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            HostPalette.backdrop.ignoresSafeArea()
            HostPalette.stageLight.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    header

                    VStack(spacing: 0) {
                        KeepAwakeRow()
                        Divider().padding(.leading, 52)
                        KeepAwakeScheduleRow()
                        Divider().padding(.leading, 52)
                        WakeScheduleRow()
                        Divider().padding(.leading, 52)
                        LidCloseSleepRow()
                    }
                    .hostPanel()

                    Button("Continue", action: onContinue)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 36)
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 560, idealHeight: 680)
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 76, height: 76)
                .background(HostPalette.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(spacing: 8) {
                Text("Leaving this Mac at home")
                    .font(HostDisplayFont.display(34))
                    .tracking(-1)
                    .multilineTextAlignment(.center)

                Text("Optional, and both off to begin with. Turn them on to close the lid, walk out, and still reach this Mac from your iPhone. Change these anytime from Settings.")
                    .font(.system(size: 15))
                    .foregroundStyle(HostPalette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
    }
}

#Preview {
    AwaySwitchesOnboardingView(onContinue: {})
        .environment(HostModel())
}
