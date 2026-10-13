import PeeringKit
import SwiftUI

/// What the keyboard bar shows while listening: a live waveform, the words as they are recognised, and the two ways out.
struct DictationOverlay: View {
    let dictation: VoiceDictation
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            roundButton(symbol: "xmark", filled: false, label: String(localized: "Cancel", table: "Dictation"), action: cancel)
            VStack(alignment: .leading, spacing: 6) {
                DictationWaveform(levels: dictation.levels.bars, isLive: dictation.state == .listening)
                    .frame(height: 46)
                DictationWords(text: dictation.transcript, placeholder: placeholder)
                    .frame(height: 24)
            }
            roundButton(symbol: "checkmark", filled: true, label: String(localized: "Done", table: "Dictation"), action: finish)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var placeholder: String {
        dictation.state == .listening ? String(localized: "Listening…", table: "Dictation") : ""
    }

    private func roundButton(symbol: String, filled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(filled ? ColorPalette.onInk : .white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(filled ? ColorPalette.ink : Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.9, haptic: true))
        .accessibilityLabel(label)
    }
}

/// The words as they are recognised: each new one rises in out of a blur, the newest in full white and the older ones fading toward the left edge, so the line reads like a ticker.
private struct DictationWords: View {
    let text: String
    let placeholder: String

    private var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        let words = words
        ZStack(alignment: .trailing) {
            if words.isEmpty {
                Text(placeholder)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        Text(word)
                            .font(.system(size: 17, weight: index == words.count - 1 ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(index == words.count - 1 ? 1 : 0.72))
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.blurReplace.combined(with: .offset(y: 8)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .clipped()
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 1)], startPoint: .leading, endPoint: .trailing)
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: words.count)
        .accessibilityLabel(text)
    }
}

/// Bars that rise with the voice, newest on the right, so the line reads as sound travelling left. Quiet is a row of dots rather than nothing, so it never looks broken.
private struct DictationWaveform: View {
    let levels: [Float]
    let isLive: Bool

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let pitch = size.width / CGFloat(count)
            let width = max(2, pitch * 0.55)
            for (index, level) in levels.enumerated() {
                let height = max(width, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * pitch + (pitch - width) / 2,
                    y: (size.height - height) / 2,
                    width: width,
                    height: height
                )
                let recency = 0.35 + 0.65 * Double(index + 1) / Double(count)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(.white.opacity(isLive ? recency : 0.3)))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

/// Shown in the bar's place when listening cannot start.
struct DictationNotice: View {
    let denied: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(denied
                ? String(localized: "Turn on Microphone and Speech Recognition for Peering in Settings.", table: "Dictation")
                : String(localized: "Dictation is not available right now.", table: "Dictation"))
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            if denied {
                Button(String(localized: "Settings", table: "Dictation")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    dismiss()
                }
                .font(.footnote.weight(.semibold))
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
            }
            .accessibilityLabel(String(localized: "Close", table: "Dictation"))
        }
        .foregroundStyle(.white)
    }
}
