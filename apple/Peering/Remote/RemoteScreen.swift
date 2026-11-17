import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

/// The stack the session lives in: the mode picker at its root, with the Mac's picture or the Agents hub pushed over it. The picture's own state lives in ``SessionSurface``, so it animates as part of the page that shows it.
struct RemoteScreen: View {
    @Environment(SessionModel.self) var model
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass

    @State var route: [RemoteRoute] = []
    @State var showsModePicker = false
    @State var watching: ChatWatch?

    var body: some View {
        NavigationStack(path: pushedRoute) {
            modeRoot
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: RemoteRoute.self) { route in
                    switch route {
                    case .screen:
                        surface
                            .analyticsScreen(.session)
                            .toolbar(showsRemoteBar ? .visible : .hidden, for: .navigationBar)
                            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
                            .toolbar { remoteToolbar }
                            .navigationBarBackButtonHidden(!showsRemoteBar)
                            .navigationTitle(model.shownHostName ?? String(localized: "this Mac"))
                            .navigationBarTitleDisplayMode(.inline)
                            .interactivePopDisabled()
                    case .hub: TerminalPanel(route: $route)
                    case .step(let step): TerminalPanel(route: $route, step: step)
                    }
                }
        }
        // On the stack's owner and not on a page: a page's handlers run again each time a pop reveals it.
        .onChange(of: model.phase) { _, phase in
            if phase == .ready { resolveSessionMode() }
        }
        // Not `onChange(initial: true)`: that runs inside the stack's first render, and a path set then reaches SwiftUI before the `navigationDestination` is registered. It answers with its yellow missing-destination triangle over black and resets the path, so a remembered mode opened as a dead page. Picking by hand came seconds later, which worked.
        .task {
            await Task.yield()
            if model.phase == .ready { resolveSessionMode() }
        }
        .onChange(of: model.activeSessionID) { _, _ in
            endWatchIfMacChanged()
            resolveSessionMode()
        }
        .onChange(of: route) { _, route in
            endWatchIfHubOpened(route)
        }
        // **The Mac's answer moves the screen, never the tap.** A new shell or chat has no id until the Mac says so; the note is cleared so it opens once.
        .onChange(of: model.newTerminalID) { _, id in
            guard let id else { return }
            model.newTerminalID = nil
            openCreated(.terminal(id))
        }
        .onChange(of: model.newAgentSessionID) { _, id in
            guard let id else { return }
            model.newAgentSessionID = nil
            openCreated(.chat(id))
        }
        .onChange(of: InAppBanner.shared.openRequest, initial: true) { _, _ in
            openFromBanner()
        }
        .overlay { hubSplit }
        .overlay { backToChat }
        .animation(Motion.settle, value: watching)
        .environment(\.watchOnMac, { watchOnMac(from: $0) })
    }

    private var surface: some View {
        SessionSurface(route: $route, openModePicker: { openModePicker() })
    }

    @ViewBuilder
    private var modeRoot: some View {
        if SessionModeFlow.rootIsPicker(modeResolved: model.activeSession?.modeResolved == true, asking: showsModePicker) {
            SessionModePicker(
                modes: SessionMode.allCases,
                hostName: model.shownHostName ?? String(localized: "this Mac"),
                onChoose: { chooseMode($0, source: "picker") },
                onCancel: model.activeSession?.modeResolved == true ? { closeModePicker() } : nil
            )
        } else {
            // Not the picture: it is only ever built as a pushed page, so no second display layer exists for the moment before the mode resolves.
            ColorPalette.backdrop.ignoresSafeArea()
        }
    }
}
