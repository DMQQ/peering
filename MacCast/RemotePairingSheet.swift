import RemoteCore
import SwiftUI
import UIKit

/// Pairing with a Mac that is not on this network, from an ID typed, pasted or scanned.
///
/// A sheet rather than an entry in the list of nearby Macs, because that list is what Bonjour
/// found and there is nothing to find here: the whole point of this screen is a Mac that is
/// not on this network and cannot be discovered. What the user brings to it is the one thing
/// that reaches across networks, which is the Mac's device ID.
struct RemotePairingSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var identifier = ""

    /// A refusal, and the text it was about.
    ///
    /// The two are kept together so the sentence disappears exactly when the text it described
    /// does — the alternative, clearing it from `onChange`, is a race: a scan sets the field
    /// and submits in the same turn, and the change callback runs after that and would wipe the
    /// very refusal the scan produced.
    private struct Refusal: Equatable {
        let text: String
        let error: PairingPayloadError
    }

    /// What was wrong with the last thing tried, kept next to the field it came from rather
    /// than in the connection failure card: this is about the text in front of the user, which
    /// is still there to be corrected.
    @State private var refusal: Refusal?
    @State private var showsScanner = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                // The screen's name in the app's display face, rather than a navigation title.
                //
                // An inline title is set by iOS, in the system face, at a size iOS chooses — which
                // made this the one screen in the app whose name was not the display face, at the
                // size of a nav bar rather than of a heading. It also read as a label on the sheet
                // rather than as the name of a screen: every other title here is 34 points of
                // serif, and this was 17 of San Francisco in a grey bar above the content.
                //
                // ``TabScreenHeader`` rather than a `Text` set to the same face, so that a change
                // to how the app titles a screen reaches this one too.
                TabScreenHeader(String(localized: "Pair from Another Network"))

                // The screen opens on the thing it is for, in the card the rest of the app puts
                // its settings in — the SSHLockSheet's shape above the same backdrop. It used to
                // open on a paragraph of instructions with the field below it, which put the
                // directions before the subject and left the ID looking like the third item on a
                // list of three equal ones.
                Controls.card(String(localized: "Device ID"), footer: footer) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Paste or type it here", text: $identifier, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .submitLabel(.go)
                            .font(.system(size: 15, design: .monospaced))
                            .textFieldStyle(.plain)
                            .focused($fieldFocused)
                            .onSubmit(submit)
                            // Wrapping rather than kept to one line: this is 36 characters of
                            // hexadecimal, and a field that scrolls sideways hides the back half
                            // of the very thing the user came here to check.
                            .lineLimit(1...3)
                            .padding(12)
                            .background(
                                .white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )

                        Controls.divider

                        // The two ways in, as rows rather than as buttons: neither is what this
                        // screen is *for*, they are how the ID reaches the field, and Pair is the
                        // only thing here that should look like the way out.
                        fillRow("Paste from the clipboard", systemImage: "doc.on.clipboard") {
                            // The whole reason this row exists is that the ID came from another
                            // machine and is 36 characters of hexadecimal nobody types from memory.
                            if let text = UIPasteboard.general.string { identifier = text }
                        }

                        Controls.divider

                        fillRow("Scan the code on the Mac", systemImage: "qrcode.viewfinder") {
                            fieldFocused = false
                            showsScanner = true
                        }
                    }
                }

                if let refusal, refusal.text == identifier {
                    Text(refusal.error.errorDescription ?? String(localized: "That is not a Mac's device ID."))
                        .font(.caption)
                        .foregroundStyle(ColorPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !model.allowsRelay {
                    // Said before the button rather than after a failure, because this is a
                    // setting rather than a mistake: no device ID will work while it is off.
                    Text("Remote access is turned off in Settings. Turn it on to reach a Mac from another network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: submit) {
                    Label("Pair", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                // Both states are named rather than left to the button style. With the tint held
                // at ink and the label held at black, the disabled state was a black label on the
                // near-black the style dims a white fill to: the sheet opened with its one
                // button invisible, which reads as a broken screen rather than as a full one.
                .tint(canPair ? ColorPalette.ink : .white.opacity(0.16))
                .foregroundStyle(canPair ? ColorPalette.onInk : .white.opacity(0.55))
                .disabled(!canPair)

                Spacer(minLength: 0)
            }
            .padding(24)
            // Painted rather than inherited. Every other sheet in the app sits on the same
            // near-black as the screen that opened it; this was the one that came up on the
            // system's own grey and read as a piece of iOS that had landed on top of Peering.
            .background(ColorPalette.backdrop)
            // No navigation bar, and with it no Cancel. Dismissing is the drag the sheet already
            // invites at this height, and a button whose only job is to repeat a gesture is one more
            // thing on a screen whose whole content is a field and one action. The name the bar was
            // carrying is in the content above, where it can be set in the display face.
            //
            // The two lines below are the whole of that trade: taking the bar away also takes away
            // the only thing that said "this can be dragged", so the indicator says it instead, and
            // nothing is lost to the user who reads the screen by looking at it rather than by
            // trying it.
            .toolbar(.hidden, for: .navigationBar)
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
        // Medium, so the whole screen is one glance: the name, the card, the field in it, and the
        // two ways of filling it. The keyboard is raised by tapping the field rather than on
        // arrival, because a keyboard that appears by itself at this height leaves the card and the
        // button off screen at the moment they are being read.
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showsScanner) {
            NavigationStack {
                PairingCodeScanner { payload in
                    showsScanner = false
                    // Whatever was scanned goes into the field and through the same door as
                    // typed text, so a scan that turns out to be the wrong kind of code
                    // produces exactly the sentence typing it would have, with the value that
                    // caused it visible underneath.
                    //
                    // `true`, and it is the honest answer for this screen rather than a formality:
                    // this one refuses nothing, the sheet closes on any code, and the judgement
                    // about whether it was a usable one is made in the sheet behind, where the
                    // sentence and the value both are.
                    identifier = payload
                    submit()
                    return true
                }
                .ignoresSafeArea()
                .navigationTitle("Scan the Mac's code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showsScanner = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Whether there is anything to pair with yet.
    ///
    /// Named once because two things read it — the button's tint and its `disabled` — and those
    /// two disagreeing is a control that looks live and does nothing, or looks dead and works.
    private var canPair: Bool {
        !model.isBusy
            && model.allowsRelay
            && !identifier.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One of the two ways to fill the field.
    ///
    /// A row rather than a button because both of them are the same kind of thing, a way in, and
    /// neither is the screen's action.
    ///
    /// **The chevron is gone, and this is the row where that cost something.** It was here to say
    /// that a row with a glyph and a name can be tapped, which is a job nothing else on these two
    /// rows does. What replaces it is context: they sit directly under the field they fill, in the
    /// same card, which is where a hand goes when a field is empty. If they ever read as labels,
    /// this is the first place to put it back.
    ///
    /// It went because a chevron means "there is somewhere further on", and both of these do their
    /// work without leaving the sheet: one puts the clipboard in the field, the other opens the
    /// scanner. Keeping it here would have been the one place in the app where an arrow promised a
    /// destination and delivered an action.
    private func fillRow(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Controls.row(title, systemImage: systemImage) {
                EmptyView()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.98))
        .accessibilityLabel(title)
    }

    /// Where the ID comes from, and what it costs.
    ///
    /// The honest limitation belongs on the screen that creates the expectation, and this is the
    /// only screen that creates it. This pairing is as secure as the one across a desk because it
    /// *is* the one across a desk: the six digits are compared by two people, and nothing about
    /// the relay replaces that. What this path removes is the network requirement, not the second
    /// pair of eyes.
    private var footer: String {
        """
        The ID is on the Mac's Devices screen. Someone has to be at the Mac either way: it shows \
        six digits, you type them here, and the pairing finishes only when they match.
        """
    }

    /// Hands the text to the model and gets out of the way.
    ///
    /// The sheet closes on a start and on a refusal from the model, and only a bad ID keeps it
    /// open — the connection itself reports through the failure card on the Connect screen,
    /// which is where the user will be looking once this is gone and where a relay that cannot
    /// find the Mac has its own sentence.
    private func submit() {
        fieldFocused = false
        if let failure = model.pairWithRemoteMac(hostID: identifier) {
            refusal = Refusal(text: identifier, error: failure)
        } else {
            dismiss()
        }
    }
}
