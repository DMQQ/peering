import SwiftUI

/// Every answer is behind a tap so the list reads as an index. Answers are checked against the app, not the plan: a promise about a control that does not exist is worse than a missing feature, hence the Known gaps section.
struct FAQView: View {
    @State private var opened: Set<String> = []

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TabScreenHeader(
                        String(localized: "FAQ"),
                        detail: String(localized: "Pairing, privacy, and what moves between your devices.")
                    )

                    ForEach(Self.sections) { section in
                        sectionView(section)
                    }

                    sourceLink
                }
                .adaptiveContentColumn()
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var sourceLink: some View {
        Link(destination: PeeringSite.source) {
            HStack {
                Text("Read the source on GitHub")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ColorPalette.ink)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .cardSurface()
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(section.title)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    row(item, isLast: index == section.items.count - 1)
                }
            }
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: QA, isLast: Bool) -> some View {
        let isOpen = opened.contains(item.id)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.tap) {
                    if isOpen { opened.remove(item.id) } else { opened.insert(item.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.question)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 11)
                // The whole row is the target: a question wraps on a narrow phone.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.question)
            .accessibilityHint(isOpen ? "Hide the answer" : "Show the answer")

            if isOpen {
                Text(item.answer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }

            if !isLast {
                Divider()
                    .overlay(.white.opacity(0.07))
            }
        }
    }

    struct QA: Identifiable {
        var id: String { question }
        let question: String
        let answer: String
    }

    struct Section: Identifiable {
        var id: String { title }
        let title: String
        let items: [QA]
    }
}

#Preview {
    NavigationStack { FAQView() }
        .preferredColorScheme(.dark)
}
