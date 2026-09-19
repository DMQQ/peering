import SSHCore
import SwiftUI

/// The Servers tab: the machines saved by hand, and whichever shell is open.
///
/// A tab of its own rather than a section of the Connect screen, because the two lists are answers
/// to different questions. Connect answers "which of my Macs is this" — discovery, pairing, a
/// connection that carries video. This answers "which server do I want a shell on", where the list
/// is typed in by hand and nothing is discovered. Putting them in one card would mean one list
/// where half the rows behave nothing like the other half.
struct SSHTab: View {
    /// Owned by the app rather than by this screen, because an intent has to be able to open a
    /// shell before this screen has ever been built — see ``MacCastApp``.
    @Environment(SSHModel.self) private var model

    @State private var isAdding = false
    @State private var editingHost: SSHHost?
    @State private var password = ""
    @State private var rememberPassword = true

    /// The host whose password is being asked for. The model holds it rather than this screen,
    /// because the request can come from Siri as easily as from a tap.
    private var isAskingForPassword: Binding<Bool> {
        Binding(
            get: { model.pendingPasswordHost != nil },
            set: { if !$0 { model.pendingPasswordHost = nil } }
        )
    }

    /// The server a lock is asking about. Held on the model for the same reason the password is:
    /// the request can arrive from a Shortcut, before this screen has ever been built.
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
            SSHHostEditor(existing: nil, hasStoredPasscode: false) { host, secrets in
                model.save(host, passcode: secrets.passcode)
                if let typed = secrets.password {
                    model.store(password: typed, for: host, remember: secrets.rememberPassword)
                }
            }
        }
        .sheet(item: $editingHost) { host in
            SSHHostEditor(existing: host, hasStoredPasscode: model.hasPasscode(for: host)) { updated, secrets in
                model.save(updated, passcode: secrets.passcode)
                if let typed = secrets.password {
                    model.store(password: typed, for: updated, remember: secrets.rememberPassword)
                }
            }
        }
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
                    TabScreenHeader("Servers", detail: "Shells on machines you added by hand.")

                    // A shell keeps running while the list is up — leaving the screen is not
                    // hanging up — so the list has to offer a way back to it. Without this the
                    // session would still be open with nothing on screen that says so, which is
                    // the worst of both: a connection the user is paying for and cannot reach.
                    if !model.openShells.isEmpty {
                        card("Open", systemImage: "terminal") {
                            // `openShells`, not every terminal: a connection that failed has no
                            // session behind it, and a row offering to go back to it is a row
                            // that leads to the same error a second time.
                            ForEach(model.openShells) { open in
                                openRow(open)
                            }
                        }
                    }

                    card("Servers", systemImage: "server.rack") {
                        if model.hosts.isEmpty {
                            emptyRow
                        } else {
                            ForEach(model.hosts) { host in
                                row(host)
                            }
                        }
                    }

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
                }
                .padding(18)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
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

    /// A card of rows, in the shape the Connect and Sessions tabs already use: a sentence-case
    /// heading with a glyph, then one raised surface per row.
    ///
    /// Deliberately not ``Controls/card(_:footer:content:)``, which is the Settings tab's shape —
    /// an uppercase label over rows that share one surface and are divided by rules. The two are
    /// different answers to "what is this screen made of". Settings is a list of *settings*, where a
    /// rule between two of them draws the eye across a boundary that means nothing; this is a list
    /// of *objects*, where each row is a thing with its own name, its own state and its own menu,
    /// and the gap between them is the point.
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

    /// One saved server, drawn as the Connect tab draws a trusted Mac — the same tile, the same
    /// two lines, the same surface per row and the same ellipsis at the end. The two are the same
    /// kind of thing to a reader: a machine this phone can open, with a name and an address, and a
    /// set of things you might want to do to it that are not the tap.
    private func row(_ host: SSHHost) -> some View {
        HStack(spacing: 10) {
            // Through the gate rather than straight to `open`, so a locked server asks first. The
            // whole of that decision lives on the model, because this row is not the only way in.
            Button { model.requestOpen(host) } label: {
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

                    // No chevron: both of these rows *do* something rather than lead somewhere. A
                    // server row opens a shell on it, and an open-shell row comes back to the one
                    // already running, and neither is a place a chevron could point at.
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

    /// The second line: what the server is, and what it will ask for.
    ///
    /// The lock belongs here rather than as a glyph by the chevron, which is where it started. The
    /// detail line is where a trusted Mac says "Nearby · tap to connect" — the sentence about what
    /// tapping is going to do — and a server that is going to ask for a passcode is saying the same
    /// kind of thing. It also survives truncation in a way a bare padlock does not: the padlock by
    /// the chevron had no room to say *which* lock, and this has room to say that there is one.
    private func serverDetail(_ host: SSHHost) -> String {
        host.lock.isLocked ? "\(host.detail) · Locked" : host.detail
    }

    /// The things that are not the tap.
    ///
    /// A menu on the row rather than the long-press it was, which is what the trusted Macs have and
    /// for the reason they have it: a long press is a gesture nothing on the screen mentions, and
    /// "Forget its key" is the one control a user needs exactly when the connection has stopped
    /// working — which is the worst possible moment to be told to press and hold.
    private func rowMenu(_ host: SSHHost) -> some View {
        Menu {
            // The second shell, which the plain tap deliberately does not give you.
            Button("New shell", systemImage: "plus.rectangle.on.rectangle") { openAnother(host) }
            Button("Edit…", systemImage: "pencil") { editingHost = host }

            if model.isKeyKnown(for: host) {
                // The only route past a changed key. Named for what it does rather than for the
                // problem it solves, because the screen that says "the key changed" is where the
                // user will come looking for it.
                Button("Forget its key", systemImage: "key.slash", role: .destructive) {
                    model.forgetKey(for: host)
                }
            }

            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(host) }
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

    /// A shell that is already open. Tapping it goes back to it rather than opening a second one —
    /// the row names the machine, and the machine is what it is already connected to.
    private func openRow(_ open: SSHTerminal) -> some View {
        // Siblings, not nested: a tap on the close must not also mean "go to this shell".
        HStack(spacing: 10) {
            Button {
                model.selectedTerminalID = open.id
            } label: {
                HStack(spacing: 12) {
                    // The dot is in the corner of the tile rather than beside the name, which is
                    // where a trusted Mac carries its own — and it means the same thing here: this
                    // one is live, and here is how far along it is.
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

                    // No chevron: both of these rows *do* something rather than lead somewhere. A
                    // server row opens a shell on it, and an open-shell row comes back to the one
                    // already running, and neither is a place a chevron could point at.
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Closing from here, because the list is where a user comes when they have lost track
            // of what is open — and being told there are three shells with no way to end one from
            // the screen that counts them is the wrong place to have to go looking for a way out.
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
        // Asked at the row, not at the bottom of the screen — see ``TerminalEndPrompt``.
        .terminalEndPrompt(
            name: open.title,
            detail: "The shell on the server stops, along with anything running in it. Your other shells are left alone.",
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

    /// What the dot means, in words, on the line under the name.
    private func openStatus(_ open: SSHTerminal) -> String {
        switch open.phase {
        case .connecting: return "\(open.host.detail) · Connecting"
        case .live: return "\(open.host.detail) · Live"
        case .ended(let reason): return reason ?? "\(open.host.detail) · Ended"
        }
    }

    // MARK: - Connecting

    /// Opens another shell on a machine that already has one.
    ///
    /// Straight to ``SSHModel/open(_:password:remember:)`` rather than through the gate, which is
    /// the one deliberate way past a lock: see ``SSHModel/requestOpen(_:)``. The user is asking for
    /// a second tab on a machine they are already signed in to.
    private func openAnother(_ host: SSHHost) {
        if let stored = model.storedPassword(for: host) {
            model.open(host, password: stored, remember: false)
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
            // Cleared here rather than by whoever raised the question, because there are now three
            // of those — the row, the log, and the gate that opens a code lock — and a password
            // typed at the last one must not be waiting in the box at the next.
            .onAppear {
                password = ""
                rememberPassword = true
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.pendingPasswordHost = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { commitPassword(for: host) }
                        .disabled(password.isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(340)])
        .preferredColorScheme(.dark)
    }

    private func commitPassword(for host: SSHHost) {
        guard !password.isEmpty else { return }
        model.open(host, password: password, remember: rememberPassword)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.answerKeyPrompt(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") { model.answerKeyPrompt(true) }
                        .fontWeight(.semibold)
                }
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.height(420)])
        .preferredColorScheme(.dark)
    }
}
