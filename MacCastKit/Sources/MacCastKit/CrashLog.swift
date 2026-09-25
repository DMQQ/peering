import Darwin
import Foundation

#if canImport(MetricKit)
import MetricKit
#endif

/// Where a crash is written down, by the two things that can write one.
///
/// **The reason this exists at all: a crash that happens on launch is invisible.** Both ends of this
/// app have been debugged from `.ips` files that had to be synced to a Mac by hand and read with a
/// script. That only works when somebody thinks to go looking, and it says nothing at all about
/// anybody else's device.
///
/// There are two halves, and neither covers the other:
///
/// - **The handlers below** catch a signal or an uncaught exception *as it happens*, on this
///   launch, and write it where the next launch will find it. This is the half that catches a crash
///   on launch, because the attempt that fails is the attempt that writes.
/// - **MetricKit** reports what a signal handler cannot see at all: watchdog kills, hangs, CPU and
///   disk exceptions. Its payloads arrive about a day later and only if the app runs again, so it
///   is the taxonomy and not the alarm.
///
/// **Everything stays on the device.** MetricKit is a system framework: no account, no service, no
/// third-party SDK, and it makes no network calls of its own. Nothing here is uploaded anywhere, and
/// this type has no way to upload it.
public enum CrashLog {
    /// One thing that went wrong, and when.
    public struct Entry: Sendable, Identifiable {
        public enum Kind: String, Sendable {
            /// Written by the signal or exception handler as it happened.
            case crash
            /// A diagnostic Apple collected and handed over, about a day afterwards.
            case diagnostic
        }

        public let id: String
        public let kind: Kind
        public let date: Date
        /// The whole file, as written. Kept as text because the point is to be read.
        public let text: String
        public let url: URL
    }

    // MARK: - Where it goes

    /// The directory every file here lives in, created on demand.
    ///
    /// `Application Support` rather than `Caches`, which the system may delete at any moment, and
    /// rather than `Documents`, which on the phone is the user's own space and would put a crash
    /// report in Files.app.
    private static func directory(subject: String) -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let directory = base
            .appendingPathComponent(subject, isDirectory: true)
            .appendingPathComponent("Crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// What ``install(subject:version:)`` was told, for the MetricKit callback to file under. It
    /// arrives on MetricKit's own queue with nothing to say which app it is running in.
    ///
    /// `nonisolated(unsafe)` rather than actor-isolated, and the lock below is what actually makes
    /// it safe: this is read from a MetricKit queue and written once at launch, and neither of them
    /// is the main actor.
    nonisolated(unsafe) private static var storedSubject: String?
    private static let lock = NSLock()

    /// How many of each kind are kept. Enough to see a pattern, few enough that this never becomes
    /// something a person has to manage.
    private static let keep = 10

    // MARK: - Installing

    /// Puts the handlers in and subscribes to MetricKit. Called once, as early as the app can.
    ///
    /// - Parameters:
    ///   - subject: what to file it under. Short and filesystem-safe, so the phone and the Mac do
    ///     not write over each other when they share a machine.
    ///   - version: the build, so a report says which one it was. Read from the bundle when it is
    ///     not given, which is every real caller: a crash report whose version is wrong is worse
    ///     than one that omits it.
    public static func install(subject: String, version: String? = nil) {
        let version = version ?? bundleVersion
        guard let directory = directory(subject: subject) else { return }
        let pending = directory.appendingPathComponent("last-crash.txt")

        // **The file the last run left behind becomes a dated report, before anything can overwrite
        // it.** This is the whole of how a launch crash survives: the run that died wrote it and
        // could not do anything else, and the run that has just started is the one that can file
        // it. Its modification date is when the crash happened, which is why no clock is read in
        // the handler — formatting a time there is not a safe thing to do.
        archive(pending, into: directory)
        prune(directory, keeping: keep)

        lock.withLock { storedSubject = subject }
        prepareHandlerState(pending: pending, subject: subject, version: version)

        installExceptionHandler()

        for signalNumber in handledSignals {
            signal(signalNumber, handleSignal)
        }

        #if canImport(MetricKit)
        MXMetricManager.shared.add(metricCollector)
        #endif
    }

    /// `1.2.3 (456)`, or whatever the bundle has. Both halves, because this app's build number is a
    /// date and the version is the same date: a report that said only one of them would be
    /// ambiguous between two builds of the same day.
    private static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(short) (\(build))"
    }

    private static func archive(_ pending: URL, into directory: URL) {
        guard let text = try? String(contentsOf: pending, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            try? FileManager.default.removeItem(at: pending)
            return
        }

        // Dated by the file's own modification time rather than by now: the file was written at the
        // moment of the crash, and this runs at the next launch.
        let when = (try? pending.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let stamp = ISO8601DateFormatter().string(from: when)
            .replacingOccurrences(of: ":", with: "-")
        let destination = directory.appendingPathComponent("crash-\(stamp).txt")
        try? text.write(to: destination, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: pending)
    }

    /// Drops the oldest reports of both kinds until `keep` of each are left.
    private static func prune(_ directory: URL, keeping keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        for prefix in ["crash-", "metrickit-"] {
            let matching = files
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
                .sorted { left, right in
                    let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return l > r
                }
            for stale in matching.dropFirst(keep) {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }

    // MARK: - Reading

    /// Everything that has been filed, newest first.
    public static func entries(subject: String) -> [Entry] {
        guard let directory = directory(subject: subject) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return files.compactMap { url -> Entry? in
            let name = url.lastPathComponent
            let kind: Entry.Kind
            if name.hasPrefix("crash-") {
                kind = .crash
            } else if name.hasPrefix("metrickit-") {
                kind = .diagnostic
            } else {
                return nil
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return Entry(id: name, kind: kind, date: date, text: text, url: url)
        }
        .sorted { $0.date > $1.date }
    }

    /// Throws away everything filed so far, for the button beside the list.
    public static func clear(subject: String) {
        guard let directory = directory(subject: subject) else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// The first line of the newest crash, for a row that has no space for the rest.
    public static func headline(of entry: Entry) -> String {
        entry.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "crash"
    }
}

// MARK: - The handler

/// The signals worth catching. `SIGKILL` is absent on purpose: the watchdog and the system kill the
/// process rather than crashing it, and nothing in the process is given the chance to run. That is
/// the half MetricKit covers and this half cannot.
private let handledSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

/// A C string per handled signal, so the handler has something to write without formatting it.
///
/// Indexed by signal number. Built at install time because building a string inside a signal
/// handler means allocating, and only a fixed set of calls are safe there.
nonisolated(unsafe) private var signalHeaders: [UnsafeMutablePointer<CChar>?] =
    Array(repeating: nil, count: Int(NSIG))

/// The header every report starts with, and where it goes, both as C strings for the same reason.
nonisolated(unsafe) private var commonHeader: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var pendingPath: UnsafeMutablePointer<CChar>?

/// The same file as ``pendingPath``, as something Swift can open.
///
/// A file-scope global rather than a member of ``CrashLog``, and that is not tidiness:
/// `NSSetUncaughtExceptionHandler` takes a C function pointer, a closure cannot be one if it
/// captures anything, and a reference to a type's own static member counts as a capture. A global
/// does not.
nonisolated(unsafe) private var exceptionLogURL: URL?

/// Writes an uncaught exception where the next launch will file it.
///
/// **Not a signal context**, so ordinary Swift is allowed: a string, a `FileHandle`, a dictionary of
/// symbols. Appended rather than written, because an uncaught exception goes on to raise `SIGABRT`
/// and the signal handler then adds its own backtrace to the same file. Losing the reason to keep
/// the frames would be the wrong way round.
private func installExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
        let text = """
            EXCEPTION \(exception.name.rawValue)
            \(exception.reason ?? "no reason given")
            \(exception.callStackSymbols.joined(separator: "\n"))

            """
        if let url = exceptionLogURL { append(text, to: url) }
    }
}

private func prepareHandlerState(pending: URL, subject: String, version: String) {
    for pointer in signalHeaders where pointer != nil { free(pointer) }
    free(commonHeader)
    free(pendingPath)

    let process = ProcessInfo.processInfo
    let common = """
        subject: \(subject)
        version: \(version)
        os: \(process.operatingSystemVersionString)
        launch: \(ISO8601DateFormatter().string(from: Date()))

        """
    commonHeader = strdup(common)
    pendingPath = strdup(pending.path)
    exceptionLogURL = pending
    signalHeaders = Array(repeating: nil, count: Int(NSIG))
    for number in handledSignals {
        signalHeaders[Int(number)] = strdup("SIGNAL \(number) \(name(of: number))\n")
    }
}

private func name(of signalNumber: Int32) -> String {
    switch signalNumber {
    case SIGABRT: return "(abort)"
    case SIGSEGV: return "(bad memory access)"
    case SIGBUS: return "(bus error)"
    case SIGILL: return "(illegal instruction)"
    case SIGFPE: return "(arithmetic)"
    case SIGTRAP: return "(trap)"
    default: return ""
    }
}

/// Writes what happened and lets the process die.
///
/// **Only async-signal-safe calls belong in here.** `open`, `write`, `close`, `backtrace` and
/// `backtrace_symbols_fd` are the whole of the list used; a Swift string, a dictionary, a lock or
/// anything that allocates could deadlock or corrupt the heap, and the process is dying anyway, so
/// the report matters more than anything else that might run.
///
/// `backtrace_symbols_fd` writes the frames as addresses and symbols without allocating, which is
/// why it is used instead of `backtrace_symbols`. They are not symbolicated the way a `.ips` is;
/// they are enough to tell whether two crashes are the same one.
private func handleSignal(_ signalNumber: Int32) {
    let header = signalNumber < Int32(NSIG) ? signalHeaders[Int(signalNumber)] : nil
    // `_exit` rather than `exit`: the latter runs atexit handlers and flushes streams, none of
    // which is safe from a signal context. This is the path taken when install never ran, so there
    // is nothing to write.
    guard let path = pendingPath else { _exit(signalNumber) }

    let descriptor = open(path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
    if descriptor >= 0 {
        if let commonHeader { write(descriptor, commonHeader, strlen(commonHeader)) }
        if let header { write(descriptor, header, strlen(header)) }

        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, count, descriptor)

        let blank = "\n"
        write(descriptor, blank, 1)
        close(descriptor)
    }

    // Re-raise with the default handler so the crash still looks like a crash: the system's own
    // reporting, and any debugger attached, carry on as they would have.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// Appends a string normally, for the uncaught-exception handler, which does not run in a signal
/// context and can therefore use Swift.
private func append(_ text: String, to url: URL) {
    guard let data = text.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

// MARK: - MetricKit

#if canImport(MetricKit)
/// Apple's own diagnostics, which arrive about a day after the fact and cover what a signal handler
/// cannot: watchdog kills, hangs, and CPU and disk exceptions.
///
/// **Diagnostics only.** The other payload MetricKit offers is performance, launch time, memory,
/// hangs by rate, and none of that is an error to be logged; keeping it would trade a small folder
/// of readable reports for a large one nobody opens.
private let metricCollector = MetricKitCollector()

/// `@unchecked Sendable` because it has no state to race on: it is a name for the two callbacks and
/// nothing else. `MXMetricManager` holds its subscriber weakly, which is why `install` keeps this
/// one alive itself.
private final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            CrashLog.store(diagnosticPayload: payload.jsonRepresentation())
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Deliberately nothing. See the note above.
    }
}
#endif

extension CrashLog {
    /// Files one diagnostic, under the day it describes rather than the moment it arrived.
    ///
    /// The payload carries its own time range; the file is named from the moment it lands, which is
    /// the only clock this side has. Its modification date is what the list sorts on.
    static func store(diagnosticPayload data: Data) {
        guard let directory = directory(subject: subjectForStorage) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("metrickit-\(stamp).json")
        try? data.write(to: url)
        prune(directory, keeping: keep)
    }

    /// Set by ``install(subject:version:)``, because the callback arrives on MetricKit's own queue
    /// with no way to be told which app it is running in.
    private static var subjectForStorage: String {
        lock.withLock { storedSubject ?? Bundle.main.bundleIdentifier ?? "app" }
    }
}
