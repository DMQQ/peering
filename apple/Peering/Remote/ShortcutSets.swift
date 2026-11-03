import RemoteCore
import SwiftUI
import UIKit

struct ShortcutSets: View {
    let application: (name: String, row: AnyView)?
    let functionKeys: AnyView

    private enum Set: Hashable { case application, macros, functionKeys }

    @State private var chosen: Set?

    static let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    private var sets: [(Set, String)] {
        var sets: [(Set, String)] = []
        if let application { sets.append((.application, application.name)) }
        sets.append((.macros, String(localized: "Shortcuts")))
        sets.append((.functionKeys, "F1–F12"))
        return sets
    }

    private var shown: Set {
        if let chosen, sets.contains(where: { $0.0 == chosen }) { return chosen }
        return application == nil ? .macros : .application
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Shortcut set", selection: Binding(
                get: { shown },
                set: { set in withAnimation(Motion.settle) { chosen = set } }
            )) {
                ForEach(sets, id: \.0) { set, title in
                    Text(title).tag(set)
                }
            }
            .pickerStyle(.segmented)

            ViewThatFits(in: .vertical) {
                keys
                ScrollView(.vertical, showsIndicators: false) { keys }
                    .frame(maxHeight: 208)
            }
            .id(shown)
            .transition(.blurReplace(.downUp))
        }
    }
}

extension ShortcutSets {
    @ViewBuilder
    private var keys: some View {
        switch shown {
        case .application: application?.row
        case .macros: MacroBar()
        case .functionKeys: functionKeys
        }
    }
}
