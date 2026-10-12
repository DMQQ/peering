import Foundation

/// The soft limit on open files starts at 256 on macOS, which a few dozen sockets from strangers can use up.
public enum FileDescriptorLimit {
    public static let wanted: UInt64 = 8192

    /// The soft limit to ask for, or nil when it is already enough. Never above the hard limit.
    public static func target(soft: UInt64, hard: UInt64, wanted: UInt64 = FileDescriptorLimit.wanted) -> UInt64? {
        let goal = min(wanted, hard)
        return goal > soft ? goal : nil
    }

    /// Raises the soft limit for this process. Returns the new limit, or nil when nothing changed.
    @discardableResult
    public static func raise() -> UInt64? {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return nil }
        guard let goal = target(soft: UInt64(limits.rlim_cur), hard: UInt64(limits.rlim_max)) else { return nil }
        limits.rlim_cur = rlim_t(goal)
        return setrlimit(RLIMIT_NOFILE, &limits) == 0 ? goal : nil
    }
}
