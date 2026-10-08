import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

struct MacroBar: View {
    @Environment(SessionModel.self) private var model
    @State private var showingMacroEditor = false

    var body: some View {
        LazyVGrid(columns: ShortcutSets.columns, spacing: 8) {
                ForEach(model.allMacros) { macro in
                    Button {
                        model.run(macro)
                    } label: {
                        Text(macro.title)
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 8)
                            .keyChip()
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86))
                }

                // What is paid is making a macro, not using one: the built-in chips are the keyboard and free on every plan, and gating them would charge for the keyboard. On a plan without the editor the button stays, dimmed with the badge, so users can see what it does.
                PlanLocked(capability: .macros, title: String(localized: "Edit macros"), diameter: 34) {
                    Button {
                        showingMacroEditor = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .medium))
                            .keyChip()
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86))
                    .accessibilityLabel("Edit macros")
                }
        }
        .sheet(isPresented: $showingMacroEditor) {
            MacroEditorView(model: model)
        }
    }
}
