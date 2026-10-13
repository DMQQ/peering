import AVFoundation
import Observation
import PeeringKit
import Speech
import os

private let dictationLog = Logger(subsystem: "pl.dmq.peering", category: "dictation")

/// Listens through the microphone and turns speech into text, on the device when the language allows it.
@MainActor
@Observable
final class VoiceDictation {
    enum State: Equatable {
        case idle
        case listening
        /// Stopped listening and waiting for the recogniser's last word.
        case finishing
        case denied
        case unavailable
    }

    private(set) var state = State.idle
    private(set) var transcript = ""
    private(set) var levels = DictationLevels()

    var isActive: Bool { state != .idle }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?
    @ObservationIgnored private var onFinish: ((String) -> Void)?

    /// `onFinish` gets what was heard, once, when listening ends by `finish()` or by the recogniser's own end.
    func start(onFinish: @escaping (String) -> Void) {
        guard state == .idle || state == .denied || state == .unavailable else { return }
        self.onFinish = onFinish
        transcript = ""
        levels.clear()
        Task { await begin() }
    }

    /// Delivers what was heard so far, after giving the recogniser a moment to settle its last word.
    func finish() {
        guard state == .listening else { return }
        state = .finishing
        stopAudio()
        request?.endAudio()
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    func cancel() {
        onFinish = nil
        teardown()
        state = .idle
    }

    func dismissMessage() {
        if state == .denied || state == .unavailable { state = .idle }
    }

    // MARK: - Starting

    private func begin() async {
        guard await Self.authorised() else {
            state = .denied
            return
        }
        guard let recogniser = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(), recogniser.isAvailable else {
            state = .unavailable
            return
        }
        do {
            try startListening(with: recogniser)
            state = .listening
        } catch {
            dictationLog.error("could not start listening: \(String(describing: error), privacy: .public)")
            teardown()
            state = .unavailable
        }
    }

    /// Nonisolated: the system calls the authorisation callback on its own queue, and a closure inheriting the main actor traps there.
    private nonisolated static func authorised() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func startListening(with recogniser: SFSpeechRecognizer) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP])
        try session.setActive(true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recogniser.supportsOnDeviceRecognition
        self.request = request

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(feeding: request, levels: { [weak self] decibels in
            Task { @MainActor in self?.levels.add(decibels: decibels) }
        }))
        engine.prepare()
        try engine.start()
        self.engine = engine

        task = recogniser.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] text, isFinal, failed in
            Task { @MainActor in self?.heard(text, isFinal: isFinal, failed: failed) }
        })
    }

    /// Built outside the class on purpose: a closure written in a main-actor method inherits that isolation, and the audio thread calling it then traps.
    private nonisolated static func tap(
        feeding request: SFSpeechAudioBufferRecognitionRequest,
        levels: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let sink = request
        return { @Sendable buffer, _ in
            sink.append(buffer)
            levels(decibels(of: buffer))
        }
    }

    private nonisolated static func resultHandler(
        _ report: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { @Sendable result, error in
            report(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    private nonisolated static func decibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -.infinity }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        return 20 * log10(max((sum / Float(buffer.frameLength)).squareRoot(), 1e-7))
    }

    // MARK: - Hearing

    private func heard(_ text: String?, isFinal: Bool, failed: Bool) {
        guard state == .listening || state == .finishing else { return }
        if let text, !text.isEmpty { transcript = text }
        if isFinal || (failed && state == .finishing) { deliver() }
        if failed, state == .listening, transcript.isEmpty {
            teardown()
            state = .unavailable
        }
    }

    private func deliver() {
        finishTimeout?.cancel()
        finishTimeout = nil
        let heard = transcript
        let handler = onFinish
        onFinish = nil
        teardown()
        state = .idle
        handler?(heard)
    }

    // MARK: - Stopping

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func teardown() {
        finishTimeout?.cancel()
        finishTimeout = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        levels.clear()
        restorePlaybackSession()
    }

    /// What the session's own audio needs, as ``SessionAudio`` sets it.
    private func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            dictationLog.error("could not restore the playback session: \(String(describing: error), privacy: .public)")
        }
    }
}
