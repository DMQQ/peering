import MacCastKit
import SSHCore
import SwiftUI

/// The Servers tab: the machines saved by hand, and whichever shell is open.
struct SSHTab: View {
    /// Owned by the app: an intent must be able to open a shell before this screen is built.
    @Environment(SSHModel.self) private var model

    @Environment(SessionModel.self) private var session

    @AppStorage(PreferenceKeys.hasSeenTourServers) private var hasSeenTourServers = false

    @State private var isAdding = false
    @State private var editingHost: SSHHost?
    @State private var showingPublicKey: SSHHost?
    @State private var deletingCredential: SSHHost?
    @State private var password = ""
    @State private var rememberPassword = true

    /// Held on the model: the request can come from Siri as easily as from a tap.
    private var isAskingForPassword: Binding<Bool> {
        Binding(
            get: { model.pendingPasswordHost != nil },
            set: { if !$0 { model.pendingPasswordHost = nil } }
        )
    }

    /// Held on the model: the request can arrive from a Shortcut.
    private var isLocked: Binding<Bool> {
        Binding(
            get: { model.lockedHost != nil },
            set: { if !$0 { model.cancelUnlock() } }
        )
    }

    var body: some View {
        NavigationStack {
            if let terminal = model.selectedTerminal {
                SSHTerminalScreen(model: model, terminal: terminal)
            } else {
                servers
            }
        }
        .tint(ColorPalette.accent)
        .sheet(isPresented: $isAdding) {
            SSHHostEditor(existing: nil, credential: nil, hasStoredPasscode: false) { host, secrets in
                model.save(host, passcode: secrets.passcode)
                model.apply(secrets.credential, to: host, rememberPassword: secrets.rememberPassword)
            }
        }
        .sheet(item: $editingHost) { host in
            SSHHostEditor(
                existing: host,
                credential: model.storedCredential(for: host),
                hasStoredPasscode: model.hasPasscode(for: host)
            ) { updated, secrets in
                model.save(updated, passcode: secrets.passcode)
                model.apply(secrets.credential, to: updated, rememberPassword: secrets.rememberPassword)
            }
        }
        .sheet(item: $showingPublicKey) { host in
            if case .key(let key) = model.storedCredential(for: host) {
                SSHPublicKeySheet(host: host, key: key)
            }
        }
        .forgetCredentialPrompt(
            host: deletingCredential,
            isPresented: Binding(
                get: { deletingCredential != nil },
                set: { if !$0 { deletingCredential = nil } }
            ),
            onForget: {
                if let host = deletingCredential { model.forgetCredential(for: host) }
                deletingCredential = nil
            }
        )
        .sheet(isPresented: isAskingForPassword) {
            if let host = model.pendingPasswordHost {
                passwordSheet(for: host)
            }
        }
        .sheet(isPresented: isLocked) {
            if let host = model.lockedHost {
                SSHLockSheet(host: host)
            }
        }
        .sheet(isPresented: hasKeyPrompt) {
            if let prompt = model.keyPrompt {
                keyPromptSheet(prompt)
            }
        }
    }

    private var hasKeyPrompt: Binding<Bool> {
        Binding(
            get: { model.keyPrompt != nil },
            set: { if !$0 { model.answerKeyPrompt(false) } }
        )
    }

    // MARK: - The list

    private var servers: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TabScreenHeader(String(localized: "Servers"), detail: String(localized: "Shells on machines you added by hand."))

                    // A shell keeps running while the list is up, so the list must offer a way back to it.
                    if !model.openShells.isEmpty {
                        card(String(localized: "Open"), systemImage: "terminal") {
                            // `openShells`, not every terminal: a failed connection has no session to return to.
                            ForEach(model.openShells) { open in
                                openRow(open)
                            }
                        }
                        // An absent control reports no frame, and the tour drops a step with no frame.
                        .tourAnchor(.serversOpen)
                    }

                    card(String(localized: "Servers"), systemImage: "server.rack") {
                        if model.hosts.isEmpty {
                            emptyRow
                        } else {
                            ForEach(model.hosts) { host in
                                row(host)
                            }
                        }
                    }
                    .tourAnchor(.serversList)

                    Button {
                        isAdding = true
                    } label: {
                        Label("Add a server", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ColorPalette.ink)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(ColorPalette.surface)
                    }
                    .tourAnchor(.serversAdd)
                }
                .adaptiveContentColumn()
                .padding(18)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .firstRunTours(dueServerTours) { $0.markSeen() }
    }

    private var dueServerTours: [Tour] {
        hasSeenTourServers ? [] : [.servers]
    }

    private var emptyRow: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "server.rack")
            Text("A server appears here once you add it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .rowSurface()
    }

    private func card<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Controls.sectionLabel(title, systemImage: systemImage)
            VStack(spacing: 8) {
                content()
            }
        }
        .cardSurface()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ host: SSHHost) -> some View {
        HStack(spacing: 10) {
            // Through the gate so a locked server asks first; the gate lives on the model because this row is not the only way in.
            Button {
                model.requestOpen(host)
            } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: "server.rack")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorPalette.ink)
                            .lineLimit(1)
                        Text(serverDetail(host))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // No chevron: these rows do something rather than lead somewhere.
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            rowMenu(host)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .rowSurface()
    }

    private func serverDetail(_ host: SSHHost) -> String {
        host.lock.isLocked ? String(localized: "\(host.detail) · Locked") : host.detail
    }

    /// A menu rather than a long press: nothing mentions the gesture, and forgetting a key is needed exactly when the connection has failed.
    private func rowMenu(_ host: SSHHost) -> some View {
        Menu {
            Button("New shell", systemImage: "plus.rectangle.on.rectangle") {
                openAnother(host)
            }
            Button("Edit…", systemImage: "pencil") { editingHost = host }

            // Also here, not only in the editor: the user needs the key line while sitting at the server.
            if case .key = model.storedCredential(for: host) {
                Button("Public key…", systemImage: "doc.on.doc") { showingPublicKey = host }
            }

            if model.hasStoredCredential(for: host) {
                Button("Forget how to sign in", systemImage: "key.slash", role: .destructive) {
                    deletingCredential = host
                }
                .menuDanger()
            }

            if model.isKeyKnown(for: host) {
                // The only route past a changed key; the screen that says the key changed is where users look.
                Button("Forget its key", systemImage: "key.slash", role: .destructive) {
                    model.forgetKey(for: host)
                }
                .menuDanger()
            }

            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(host) }
                .menuDanger()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .menuInk()
        .accessibilityLabel("More options for \(host.displayName)")
    }

    private func openRow(_ open: SSHTerminal) -> some View {
        // Siblings, not nested: a tap on the close must not also mean "go to this shell".
        HStack(spacing: 10) {
            Button {
                model.selectedTerminalID = open.id
            } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        IconTile(symbol: "terminal")
                        Circle()
                            .fill(statusTint(open))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(ColorPalette.backdrop, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(open.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorPalette.ink)
                            .lineLimit(1)
                        Text(openStatus(open))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // No chevron: these rows do something rather than lead somewhere.
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.requestClose(open)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ColorPalette.danger)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End \(open.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .rowSurface()
        .terminalEndPrompt(
            name: open.title,
            detail: String(localized: "The shell on the server stops, along with anything running in it. Your other shells are left alone."),
            isPresented: Binding(
                get: { model.pendingClose?.id == open.id },
                set: { if !$0 { model.pendingClose = nil } }
            ),
            onEnd: {
                model.close(open)
                model.pendingClose = nil
            }
        )
    }

    private func statusTint(_ open: SSHTerminal) -> Color {
        switch open.phase {
        case .connecting: return ColorPalette.caution
        case .live: return .green
        case .ended: return ColorPalette.danger
        }
    }

    private func openStatus(_ open: SSHTerminal) -> String {
        switch open.phase {
        case .connecting: return String(localized: "\(open.host.detail) · Connecting")
        case .live: return String(localized: "\(open.host.detail) · Live")
        case .ended(let reason): return reason ?? String(localized: "\(open.host.detail) · Ended")
        }
    }

    // MARK: - Connecting

    /// Straight to open, bypassing the lock gate on purpose: the user is already signed in to this machine.
    private func openAnother(_ host: SSHHost) {
        if let stored = model.storedCredential(for: host) {
            model.open(host, credential: stored, remember: false)
        } else {
            model.pendingPasswordHost = host
        }
    }

    private func passwordSheet(for host: SSHHost) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.displayName)
                        .font(.headline)
                    Text(host.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                TextField("Password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(ColorPalette.surface)
                    }
                    .onSubmit { commitPassword(for: host) }

                Toggle("Remember it", isOn: $rememberPassword)
                    .tint(ColorPalette.accent)
                    .font(.subheadline)

                Spacer(minLength: 0)
            }
            .padding(24)
            .background(ColorPalette.backdrop)
            // Cleared here: three paths raise the question, and a password typed at the last must not wait at the next.
            .onAppear {
                password = ""
                rememberPassword = true
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(
                onCancel: { model.pendingPasswordHost = nil },
                confirm: "Connect",
                canConfirm: !password.isEmpty
            ) { commitPassword(for: host) }
        }
        .presentationDetents([.height(340)])
        .preferredColorScheme(.dark)
    }

    private func commitPassword(for host: SSHHost) {
        guard !password.isEmpty else { return }
        model.open(host, credential: .password(password), remember: rememberPassword)
        password = ""
        model.pendingPasswordHost = nil
    }

    // MARK: - The first-sight key

    private func keyPromptSheet(_ prompt: SSHKeyPrompt) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Is this the right machine?")
                        .font(.headline)
                    Text("This is the first time you have connected to \(prompt.prompt.endpoint.display). Check its fingerprint against the server itself. Most providers show it in their console, and `ssh-keygen -lf` prints it on the box.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(prompt.prompt.algorithm)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(prompt.prompt.fingerprint)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(ColorPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ColorPalette.surface)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .background(ColorPalette.backdrop)
            .navigationTitle("New server")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(onCancel: { model.answerKeyPrompt(false) }, confirm: "Trust") {
                model.answerKeyPrompt(true)
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.height(420)])
        .preferredColorScheme(.dark)
    }
}

/// An alert, see ``TerminalEndPrompt``. It destroys a key the user can only regenerate on the machine that made it.
extension View {
    func forgetCredentialPrompt(
        host: SSHHost?,
        isPresented: Binding<Bool>,
        onForget: @escaping () -> Void
    ) -> some View {
        alert("Forget how to sign in?", isPresented: isPresented) {
            // Cancel first and given the role, so Escape and a stray return land on keeping it.
            Button("Keep it", role: .cancel) { }
            Button("Forget", role: .destructive, action: onForget)
        } message: {
            Text("\(host?.displayName ?? String(localized: "This server")) will ask for a password the next time you open a shell. Nothing on the server itself is touched, and any key already in `authorized_keys` stays there.")
        }
    }
}
