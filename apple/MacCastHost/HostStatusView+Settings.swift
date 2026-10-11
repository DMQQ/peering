import AppKit
import RemoteCore
import SwiftUI

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

                TerminalHooksRow(controller: model.terminalHooks)

                Divider().padding(.leading, 52)

                analyticsRow

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
    /// A notification sent on purpose, to tell never-arrived from never-sent. A developer diagnostic, built out of Release.
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
                    .hostCaption()
            }

            Spacer(minLength: 12)

            Button("Send") { model.sendTestPush() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
#endif

    /// The snapshot behind the overview is taken every couple of seconds while the window is open; off, that loop does not run.
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
                    .hostCaption()
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $showsPreview)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                // The accent, unlike the rest of the window: a switch with no colour differs on and off only by knob position.
                .tint(HostPalette.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    var analyticsRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(analyticsEnabled ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Share anonymous usage statistics")
                    .font(.subheadline.weight(.medium))
                Text("Counts of which screens and features are used, and crash reports. Never your screen, files, commands or names, and nothing that identifies you or this Mac.")
                    .hostCaption()
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $analyticsEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(HostPalette.accent)
                .onChange(of: analyticsEnabled) { _, enabled in
                    PostHogConfiguration.setEnabled(enabled)
                }
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
                    .hostCaption()
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// A phone draws the display a few hundred points wide, so full size is scaled down about fourfold anyway.
    var captureResolutionRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Capture resolution")
                    .font(.subheadline.weight(.medium))
                // Says when it lands: the setting is read when a stream is built.
                Text("3/4 captures at 75% width and height (~56% of pixels). Half is a quarter of the pixels. Applies when the next stream starts, which is a change of source or the next connection.")
                    .hostCaption()
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

    /// Only a panel refreshing faster than 60 Hz has anything to give; doubling the rate doubles encode and send.
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
                    .hostCaption()
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

    /// Bonjour carries whatever port is bound, so only the manual-address path needs telling.
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
                    .hostCaption()
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
                    // Only while nobody is editing: overwriting under the cursor would fight the user.
                    if !portFocused { portDraft = String(bound) }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    func commitPort() {
        guard let port = UInt16(portDraft.trimmingCharacters(in: .whitespaces)), port > 0 else {
            portDraft = String(model.boundPort)
            return
        }
        model.setPort(port)
        portDraft = String(model.boundPort)
    }

    // MARK: - Devices and activity

}
