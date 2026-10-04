import AppKit
import RemoteCore
import SwiftUI

/// The rows that change what the host does.
extension HostStatusView {
    var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(String(localized: "Settings"), detail: String(localized: "Options for this Mac host."))

            VStack(spacing: 0) {
                LaunchAtLoginRow()

                Divider().padding(.leading, 52)

                KeepAwakeRow()

                Divider().padding(.leading, 52)

                KeepAwakeScheduleRow()

                Divider().padding(.leading, 52)

                WakeScheduleRow()

                Divider().padding(.leading, 52)

                LidCloseSleepRow()

                Divider().padding(.leading, 52)

                previewRow

                Divider().padding(.leading, 52)

                clientPointerRow

                Divider().padding(.leading, 52)

                captureResolutionRow

                Divider().padding(.leading, 52)

                frameRateRow

                Divider().padding(.leading, 52)

                codecRow

                Divider().padding(.leading, 52)

                portRow

#if DEBUG
                Divider().padding(.leading, 52)

                pushTestRow
#endif
            }
            .hostPanel()
        }
    }

#if DEBUG
    /// A notification sent on purpose, so that "it has never arrived" can be told apart from "it
    /// was never sent". A diagnostic for a developer chasing an APNs problem, not a row a shipped
    /// Mac should carry, so it is built out of the Release configuration the install script uses.
    var pushTestRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Send a test notification")
                    .font(.subheadline.weight(.medium))
                Text(model.pushTestResult ?? String(localized: "Pushes a banner to the devices this Mac has a token for, over the relay. What this can see is the token and the send; the relay holds the APNs key and answers nothing."))
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button("Send") { model.sendTestPush() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
#endif

    /// Whether the window shows a live still of the Mac.
    ///
    /// The only setting here that is about what this Mac does when nobody is connected to it:
    /// the snapshot behind the overview is taken every couple of seconds for as long as the
    /// window is open, whether or not anyone is looking at it. Off, that loop does not run.
    var previewRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(showsPreview ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Live preview")
                    .font(.subheadline.weight(.medium))
                Text("Refreshes this window every couple of seconds with what the Mac is showing. Turning it off stops the snapshots altogether. An iPhone that is streaming still sees the screen.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $showsPreview)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                // The accent, unlike everything else in this window. The window's controls are
                // tinted with the ink so that buttons do not come back as white pills — but a
                // switch is not a button, and with no colour an on one and an off one differ
                // only by which end the knob is at. Blue for "on" is both what macOS means by it
                // and what this app's own accent already means everywhere else.
                .tint(HostPalette.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Pointer rendering belongs to the client. Keeping this visible explains why the cursor is
    /// absent from screenshots while avoiding a setting that no longer affects the stream.
    var clientPointerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.success)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Instant pointer")
                    .font(.subheadline.weight(.medium))
                Text("The Mac cursor is hidden from the video. Peering draws it on your iPhone immediately, so it follows your touch without waiting for a frame.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The size of the picture, which is the setting that trades quality for everything else
    /// at once.
    ///
    /// Worth a switch rather than a constant because of what it is measured against: a phone
    /// draws the whole display a few hundred points wide, so a stream at the display's own
    /// size is already being scaled down by a factor of four before anyone looks at it, and
    /// the pixels given up here are ones the phone was going to throw away.
    /// The size of the picture, which is the setting that trades quality for everything else
    /// at once.
    ///
    /// Worth a switch rather than a constant because of what it is measured against: a phone
    /// draws the whole display a few hundred points wide, so a stream at the display's own
    /// size is already being scaled down by a factor of four before anyone looks at it, and
    /// the pixels given up here are ones the phone was going to throw away.
    var captureResolutionRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Capture resolution")
                    .font(.subheadline.weight(.medium))
                // Says when it lands, because the switch cannot show it: the setting is read
                // when a stream is built, so a change made with a phone attached looks like
                // one that did nothing until the next capture is started.
                Text("3/4 captures at 75% width and height (~56% of pixels). Half is a quarter of the pixels. Applies when the next stream starts, which is a change of source or the next connection.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker("", selection: Binding(
                get: { model.captureResolution },
                set: { model.setCaptureResolution($0) }
            )) {
                ForEach(CaptureResolution.allCases, id: \.self) { resolution in
                    Text(resolution.title).tag(resolution)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// How many frames a second the stream is asked for.
    ///
    /// The setting for a Mac whose screen moves faster than the phone can be shown it. Only a
    /// panel that refreshes faster than sixty times a second has anything to give here, and
    /// doubling the rate doubles what has to be encoded and sent.
    /// How many frames a second the stream is asked for.
    ///
    /// The setting for a Mac whose screen moves faster than the phone can be shown it. Only a
    /// panel that refreshes faster than sixty times a second has anything to give here, and
    /// doubling the rate doubles what has to be encoded and sent.
    var frameRateRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Frame rate")
                    .font(.subheadline.weight(.medium))
                Text("30 fps saves bandwidth and battery. 60 fps is the standard. 120 fps only gains anything on a ProMotion display and doubles what must be sent. Applies when the next stream starts.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker("", selection: Binding(
                get: { model.captureFrameRate },
                set: { model.setCaptureFrameRate($0) }
            )) {
                ForEach(CaptureFrameRate.allCases, id: \.self) { rate in
                    Text(rate.title).tag(rate)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    var codecRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Video codec").font(.subheadline.weight(.medium))
                Text("HEVC saves bandwidth on supported devices. Applies when the next stream starts.")
                    .font(.caption).foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Picker("", selection: Binding(get: { model.captureCodec }, set: { model.setCaptureCodec($0) })) {
                ForEach(VideoCodec.allCases, id: \.self) { codec in Text(codec.title).tag(codec) }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    /// The port, as a field rather than the label it used to be.
    ///
    /// A Mac sharing its network with something already on 51515 had nowhere to go, and the
    /// number was a constant compiled into both apps. Bonjour carries whatever is bound here, so
    /// a phone on this network needs no change of its own; only the manual-address path has to be
    /// told, which is what the detail line says.
    /// The port, as a field rather than the label it used to be.
    ///
    /// A Mac sharing its network with something already on 51515 had nowhere to go, and the
    /// number was a constant compiled into both apps. Bonjour carries whatever is bound here, so
    /// a phone on this network needs no change of its own; only the manual-address path has to be
    /// told, which is what the detail line says.
    var portRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.status.isListening ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Port")
                    .font(.subheadline.weight(.medium))
                Text("Phones on this network follow it automatically. Changing it restarts the listener and disconnects anyone connected.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            TextField("", text: $portDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 78)
                .multilineTextAlignment(.trailing)
                .focused($portFocused)
                .onSubmit { commitPort() }
                .onChange(of: portFocused) { _, focused in
                    if !focused { commitPort() }
                }
                .onAppear { portDraft = String(model.boundPort) }
                .onChange(of: model.boundPort) { _, bound in
                    // Only while nobody is editing it: overwriting the field under a cursor
                    // that is halfway through typing a new number would be the app arguing
                    // with the user about what they meant.
                    if !portFocused { portDraft = String(bound) }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Applies the draft, or puts the real port back if it is not one.
    /// Applies the draft, or puts the real port back if it is not one.
    func commitPort() {
        guard let port = UInt16(portDraft.trimmingCharacters(in: .whitespaces)), port > 0 else {
            portDraft = String(model.boundPort)
            return
        }
        model.setPort(port)
        portDraft = String(model.boundPort)
    }

    // MARK: - Devices and activity

    /// What the connected device is looking at.
    ///
    /// First in the window, because it is the question this app exists to answer for whoever is
    /// sitting at the Mac. Everything else — who is attached, whether a permission is granted —
    /// is context for this one fact.
}
