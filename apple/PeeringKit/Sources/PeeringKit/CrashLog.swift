import Darwin
import Foundation

#if canImport(MetricKit)
import MetricKit
#endif

/// Where a crash is written down, by the two things that can write one.
public enum CrashLog {
    /// One thing that went wrong, and when.
    public struct Entry: Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case crash
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
    static func directory(subject: String) -> URL? {
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
    nonisolated(unsafe) static var storedSubject: String?
    nonisolated(unsafe) static var runningFile: URL?
    static let lock = NSLock()

    /// How many of each kind are kept. Enough to see a pattern, few enough that this never becomes
    /// something a person has to manage.
    static let keep = 10

    // MARK: - Installing

    /// Puts the handlers in and subscribes to MetricKit. Called once, as early as the app can.
    public static func install(subject: String, version: String? = nil) {
        let version = version ?? bundleVersion
        guard let directory = directory(subject: subject) else { return }
        let pending = directory.appendingPathComponent("last-crash.txt")

        // **The file the last run left behind becomes a dated report, before anything can overwrite
        // it.** This is the whole of how a launch crash survives: the run that died wrote it and
        // could not do anything else, and the run that has just started is the one that can file
        // it. Its modification date is when the crash happened, which is why no clock is read in
        let caught = archive(pending, into: directory)
        let running = directory.appendingPathComponent("running.txt")
        fileUnexpectedExit(running, caughtCrash: caught, into: directory)
        prune(directory, keeping: keep)

        lock.withLock {
            storedSubject = subject
            runningFile = running
        }
        prepareHandlerState(pending: pending, subject: subject, version: version)

        installExceptionHandler()
        installAlternateStack()

        for signalNumber in handledSignals {
            var action = sigaction()
            action.__sigaction_u = __sigaction_u(__sa_handler: handleSignal)
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signalNumber, &action, nil)
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

    /// Files the last run's crash, and says whether there was one.
    @discardableResult
    private static func archive(_ pending: URL, into directory: URL) -> Bool {
        guard let text = try? String(contentsOf: pending, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            try? FileManager.default.removeItem(at: pending)
            return false
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
        return true
    }

    /// Drops the oldest reports of both kinds until `keep` of each are left.
    static func prune(_ directory: URL, keeping keep: Int) {
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
