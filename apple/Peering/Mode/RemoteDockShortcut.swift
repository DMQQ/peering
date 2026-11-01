import RemoteCore
import SwiftUI

/// The Mac shortcuts the trackpad offers as buttons. Codes are macOS hardware keycodes.
enum RemoteDockShortcut: CaseIterable, Identifiable {
    case spotlight, switchApp, missionControl, showDesktop, copy, paste, undo, closeWindow, quitApp, screenshot

    var id: Self { self }

    var keyCode: UInt16 {
        switch self {
        case .spotlight: 49
        case .switchApp: 48
        case .missionControl: 126
        case .showDesktop: 103
        case .copy: 8
        case .paste: 9
        case .undo: 6
        case .closeWindow: 13
        case .quitApp: 12
        case .screenshot: 21
        }
    }

    var modifiers: Modifiers {
        switch self {
        case .missionControl: .control
        case .showDesktop: []
        case .screenshot: [.command, .shift]
        default: .command
        }
    }

    var symbol: String {
        switch self {
        case .spotlight: "magnifyingglass"
        case .switchApp: "square.stack"
        case .missionControl: "rectangle.3.group"
        case .showDesktop: "menubar.dock.rectangle"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .undo: "arrow.uturn.backward"
        case .closeWindow: "xmark.square"
        case .quitApp: "power"
        case .screenshot: "camera.viewfinder"
        }
    }

    var title: String {
        switch self {
        case .spotlight: String(localized: "Spotlight")
        case .switchApp: String(localized: "Switch app")
        case .missionControl: String(localized: "Mission Control")
        case .showDesktop: String(localized: "Show desktop")
        case .copy: String(localized: "Copy")
        case .paste: String(localized: "Paste")
        case .undo: String(localized: "Undo")
        case .closeWindow: String(localized: "Close window")
        case .quitApp: String(localized: "Quit app")
        case .screenshot: String(localized: "Screenshot")
        }
    }
}

/// A grid of ``RemoteDockShortcut``s; a tap sends the chord to the Mac and closes the sheet.
struct RemoteDockShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onShortcut: (RemoteDockShortcut) -> Void

    private static let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TabScreenHeader(String(localized: "Shortcuts"))
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(RemoteDockShortcut.allCases) { shortcut in
                        Button {
                            onShortcut(shortcut)
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: shortcut.symbol)
                                    .font(.system(size: 20, weight: .medium))
                                Text(shortcut.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .foregroundStyle(ColorPalette.ink)
                            .frame(maxWidth: .infinity, minHeight: 84)
                            .cardSurface()
                        }
                        .buttonStyle(RailButtonStyle(scale: 0.95, haptic: true))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
        .background(ColorPalette.backdrop.ignoresSafeArea())
    }
}
