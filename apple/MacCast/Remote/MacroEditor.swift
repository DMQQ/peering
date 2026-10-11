import RemoteCore
import SwiftUI

struct MacroEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (Macro) -> Void

    @State private var title = ""
    @State private var selectedKey: MacroKey = MacroKey.popular[0]
    @State private var useCommand = false
    @State private var useOption = false
    @State private var useControl = false
    @State private var useShift = false

    private var modifiers: Modifiers {
        var m: Modifiers = []
        if useCommand { m.insert(.command) }
        if useOption  { m.insert(.option) }
        if useControl { m.insert(.control) }
        if useShift   { m.insert(.shift) }
        return m
    }

    private var previewTitle: String {
        if !title.isEmpty { return title }
        var parts: [String] = []
        if useControl { parts.append("⌃") }
        if useOption  { parts.append("⌥") }
        if useShift   { parts.append("⇧") }
        if useCommand { parts.append("⌘") }
        parts.append(selectedKey.label)
        return parts.joined()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Auto (from modifiers + key)", text: $title)
                }

                Section("Key") {
                    Picker("Key", selection: $selectedKey) {
                        ForEach(MacroKey.popular) { key in
                            Text(key.label).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Modifiers") {
                    Toggle("⌘ Command", isOn: $useCommand)
                    Toggle("⌥ Option", isOn: $useOption)
                    Toggle("⌃ Control", isOn: $useControl)
                    Toggle("⇧ Shift", isOn: $useShift)
                }

                Section("Preview") {
                    HStack {
                        Text("Button will show:")
                        Spacer()
                        Text(previewTitle)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Macro")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(onCancel: { dismiss() }, confirm: "Add") {
                let id = UUID().uuidString
                onAdd(Macro(id: id, title: previewTitle, keyCode: selectedKey.keyCode, modifiers: modifiers))
                dismiss()
            }
        }
    }
}

struct MacroEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var model: SessionModel
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Custom macros")) {
                    if model.customMacros.isEmpty {
                        Text("No custom macros yet. Tap + to add one.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(model.customMacros) { macro in
                            HStack {
                                Text(macro.title)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("keyCode \(macro.keyCode)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .onDelete { model.removeCustomMacro(at: $0) }
                        .onMove { model.moveCustomMacro(from: $0, to: $1) }
                    }
                }

                Section(header: Text("Built-in macros")) {
                    ForEach(Macro.defaults) { macro in
                        HStack {
                            Text(macro.title)
                            Spacer()
                            Text("built-in")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("Macros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingAdd) {
                MacroEditorSheet { macro in
                    model.addCustomMacro(macro)
                }
            }
        }
    }
}

// MARK: - Key catalogue

struct MacroKey: Identifiable, Hashable, Codable {
    let id: String
    let label: String
    let keyCode: UInt16

    static let popular: [MacroKey] = [
        MacroKey(id: "a", label: "A", keyCode: 0),
        MacroKey(id: "b", label: "B", keyCode: 11),
        MacroKey(id: "c", label: "C", keyCode: 8),
        MacroKey(id: "d", label: "D", keyCode: 2),
        MacroKey(id: "e", label: "E", keyCode: 14),
        MacroKey(id: "f", label: "F", keyCode: 3),
        MacroKey(id: "g", label: "G", keyCode: 5),
        MacroKey(id: "h", label: "H", keyCode: 4),
        MacroKey(id: "i", label: "I", keyCode: 34),
        MacroKey(id: "j", label: "J", keyCode: 38),
        MacroKey(id: "k", label: "K", keyCode: 40),
        MacroKey(id: "l", label: "L", keyCode: 37),
        MacroKey(id: "m", label: "M", keyCode: 46),
        MacroKey(id: "n", label: "N", keyCode: 45),
        MacroKey(id: "o", label: "O", keyCode: 31),
        MacroKey(id: "p", label: "P", keyCode: 35),
        MacroKey(id: "q", label: "Q", keyCode: 12),
        MacroKey(id: "r", label: "R", keyCode: 15),
        MacroKey(id: "s", label: "S", keyCode: 1),
        MacroKey(id: "t", label: "T", keyCode: 17),
        MacroKey(id: "u", label: "U", keyCode: 32),
        MacroKey(id: "v", label: "V", keyCode: 9),
        MacroKey(id: "w", label: "W", keyCode: 13),
        MacroKey(id: "x", label: "X", keyCode: 7),
        MacroKey(id: "y", label: "Y", keyCode: 16),
        MacroKey(id: "z", label: "Z", keyCode: 6),
        MacroKey(id: "return",    label: String(localized: "Return ⏎"), keyCode: 36),
        MacroKey(id: "escape",    label: String(localized: "Escape ⎋"),  keyCode: 53),
        MacroKey(id: "tab",       label: String(localized: "Tab ⇥"),     keyCode: 48),
        MacroKey(id: "space",     label: String(localized: "Space"),      keyCode: 49),
        MacroKey(id: "delete",    label: String(localized: "Delete ⌫"),  keyCode: 51),
        MacroKey(id: "fwddel",    label: String(localized: "Fwd Del ⌦"), keyCode: 117),
        MacroKey(id: "home",      label: String(localized: "Home ↖"),    keyCode: 115),
        MacroKey(id: "end",       label: String(localized: "End ↘"),     keyCode: 119),
        MacroKey(id: "pageup",    label: String(localized: "Page Up"),    keyCode: 116),
        MacroKey(id: "pagedown",  label: String(localized: "Page Down"),  keyCode: 121),
        MacroKey(id: "up",        label: "↑",          keyCode: 126),
        MacroKey(id: "down",      label: "↓",          keyCode: 125),
        MacroKey(id: "left",      label: "←",          keyCode: 123),
        MacroKey(id: "right",     label: "→",          keyCode: 124),
        MacroKey(id: "f1",  label: "F1",  keyCode: 122),
        MacroKey(id: "f2",  label: "F2",  keyCode: 120),
        MacroKey(id: "f3",  label: "F3",  keyCode: 99),
        MacroKey(id: "f4",  label: "F4",  keyCode: 118),
        MacroKey(id: "f5",  label: "F5",  keyCode: 96),
        MacroKey(id: "f6",  label: "F6",  keyCode: 97),
        MacroKey(id: "f7",  label: "F7",  keyCode: 98),
        MacroKey(id: "f8",  label: "F8",  keyCode: 100),
        MacroKey(id: "f9",  label: "F9",  keyCode: 101),
        MacroKey(id: "f10", label: "F10", keyCode: 109),
        MacroKey(id: "f11", label: "F11", keyCode: 103),
        MacroKey(id: "f12", label: "F12", keyCode: 111),
    ]
}
