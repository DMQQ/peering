import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

struct MacroBar: View {
    @Environment(SessionModel.self) private var model
    @State private var showingMacroEditor = false
    @State private var quitting: Macro?

    var body: some View {
        LazyVGrid(columns: ShortcutSets.columns, spacing: 8) {
                ForEach(model.allMacros) { macro in
                    Button {
                        // Unlike copy or paste, this one can discard unsaved work, so it asks first.
                        if macro.id == "quit" { quitting = macro } else { model.run(macro) }
                    } label: {
                        Text(macro.title)
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 8)
                            .keyChip()
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86))
                }

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
        .confirmationDialog(
            model.hostPlatform == .mac ? "Quit the active Mac app?" : "Close the active app?",
            isPresented: Binding(get: { quitting != nil }, set: { if !$0 { quitting = nil } }),
            titleVisibility: .visible
        ) {
            Button(model.hostPlatform == .mac ? "Send ⌘Q" : "Send Alt+F4", role: .destructive) {
                if let quitting { model.run(quitting) }
                quitting = nil
            }
        } message: {
            Text(model.hostPlatform == .mac ? "The Mac may ask you to save open documents first." : "The app may ask you to save open documents first.")
        }
        .sheet(isPresented: $showingMacroEditor) {
            MacroEditorView(model: model)
        }
    }
}
