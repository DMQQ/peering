import PeeringKit
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
        .sheet(isPresented: $showingMacroEditor) {
            MacroEditorView(model: model)
        }
    }
}
