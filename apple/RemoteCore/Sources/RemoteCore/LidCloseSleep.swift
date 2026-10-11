import Foundation

/// macOS has no public call that keeps a Mac awake with a closed lid; `pmset -a disablesleep 1` does it, needs admin, and outlives the process, a crash and a reboot.
public enum LidCloseSleep {
    /// Absolute, because a bare name in a sudoers rule means whatever is on the user's search path.
    public static let pmsetPath = "/usr/bin/pmset"

    /// No dot in the name: `sudo` skips files in an include directory whose name contains a `.`.
    public static let sudoersPath = "/etc/sudoers.d/peering-sleep"

    /// `disablesleep` is not per-source so `-a` selects nothing; the key is absent from `man pmset`.
    public static func command(disabled: Bool) -> String {
        "\(pmsetPath) -a disablesleep \(disabled ? "1" : "0")"
    }

    public static var grantedCommands: [String] {
        [command(disabled: true), command(disabled: false)]
    }

    // MARK: - Who the rule is for

    /// Narrower than legal account names: sudoers treats `,` `(` `)` `:` `!` `\` and `#` as syntax, and such a name breaks `sudo` machine-wide or parses as wider reach.
    public static func isValidUserName(_ name: String) -> Bool {
        // `ALL` is a sudoers keyword (case-insensitive) and would grant the commands to every account.
        guard name.uppercased() != "ALL" else { return false }

        guard let first = name.first, first.isLetter || first.isNumber || first == "_" else {
            return false
        }
        return name.allSatisfy { character in
            character.isLetter || character.isNumber
                || character == "_" || character == "-" || character == "."
        }
    }

    public enum RuleError: Error, Equatable, LocalizedError {
        case unusableUserName(String)

        public var errorDescription: String? {
            switch self {
            case .unusableUserName(let name):
                return "Peering will not write an administrator rule for the account \"\(name)\", because its name cannot be spelled safely in one."
            }
        }
    }

    // MARK: - The sudoers file

    /// `sudo` matches arguments as well as the program, so this grants only the two `pmset` commands. Run-as is `root`, not `ALL`.
    public static func sudoersFileText(user: String) throws -> String {
        guard isValidUserName(user) else { throw RuleError.unusableUserName(user) }
        return """
        # Written by Peering for "keep running with the lid closed".
        #
        # Two commands and nothing else: the switch on, and the switch off. Both run as root,
        # and both match their arguments, so no other use of pmset is granted here and neither
        # is any other program. Delete this file to take the grant away; Peering's settings
        # screen does that for you.
        #
        # Mode 0440, root:wheel. sudo refuses a file anyone else could write.

        \(user) ALL=(root) NOPASSWD: \(grantedCommands.joined(separator: ", "))

        """
    }

    // MARK: - The scripts

    /// Every step is fatal: a sudoers syntax error breaks `sudo` machine-wide and the repair is a Recovery boot. So write elsewhere, check with `visudo`, then rename atomically.
    /// The dot in the staging name is load-bearing: `sudo` ignores such files, so a kill before the rename leaves nothing it reads. Staging in `/etc/sudoers.d` keeps the rename on one filesystem.
    public static func installScript(user: String) throws -> String {
        let text = try sudoersFileText(user: user)
        return """
        set -e
        staged=/etc/sudoers.d/.peering-sleep.new
        checked=$(/usr/bin/mktemp /tmp/peering-sleep.XXXXXX)
        trap '/bin/rm -f "$checked" "$staged"' EXIT
        /usr/bin/printf '%s' \(quoted(text)) > "$checked"
        /usr/sbin/visudo -cf "$checked" > /dev/null
        /usr/bin/install -o root -g wheel -m 0440 "$checked" "$staged"
        /bin/mv -f "$staged" \(quoted(sudoersPath))
        """
    }

    /// Sleep first, then the file: removing the rule while `disablesleep` is 1 would leave a Mac that will not sleep and nothing to undo it.
    public static func removeScript() -> String {
        """
        set -e
        \(pmsetPath) -a disablesleep 0
        /bin/rm -f \(quoted(sudoersPath))
        """
    }

    /// The prompt is passed explicitly because the default does not say which changes are being made.
    public static func administratorScript(shellScript: String, prompt: String) -> String {
        "do shell script \(appleScriptLiteral(shellScript)) with administrator privileges with prompt \(appleScriptLiteral(prompt))"
    }

    /// The inner shell script holds backslashes from ``quoted(_:)``; getting this wrong runs a different script as root.
    public static func appleScriptLiteral(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Same rule as ``ShellPath/quoted(_:)``, repeated because this one is on the other side of a root prompt.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Reading the machine

    public enum SleepDisabledState: Equatable, Sendable {
        case on
        case off
        /// A third answer rather than a guess: reading an unparseable line as off would leave a Mac unable to sleep.
        case unknown
    }

    /// Matched on the key in the first column: the output also has lines like `sleep 0 (sleep prevented by ...)`.
    public static func sleepDisabledState(inPMSetOutput output: String) -> SleepDisabledState {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled" else { continue }
            switch fields.dropFirst().first {
            case "1": return .on
            case "0": return .off
            default: return .unknown
            }
        }
        return .unknown
    }

    public struct Grants: Equatable, Sendable {
        public var disablesSleepOn: Bool
        public var disablesSleepOff: Bool

        public var coversBoth: Bool { disablesSleepOn && disablesSleepOff }

        public init(disablesSleepOn: Bool = false, disablesSleepOff: Bool = false) {
            self.disablesSleepOn = disablesSleepOn
            self.disablesSleepOff = disablesSleepOff
        }
    }

    /// Asked of `sudo`, not the disk: the file is unreadable without root and the question is whether `sudo` honours it. Wrapped listing lines are joined.
    public static func grants(inSudoListing listing: String) -> Grants {
        var granted = Grants()
        for entry in sudoEntries(in: listing) {
            guard let marker = entry.range(of: "NOPASSWD:") else { continue }
            let commands = entry[marker.upperBound...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if commands.contains(command(disabled: true)) { granted.disablesSleepOn = true }
            if commands.contains(command(disabled: false)) { granted.disablesSleepOff = true }
        }
        return granted
    }

    /// An entry begins with a bracketed run-as specification; anything else is a continuation.
    private static func sudoEntries(in listing: String) -> [String] {
        var entries: [String] = []
        for line in listing.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("(") || entries.isEmpty {
                entries.append(trimmed)
            } else {
                entries[entries.count - 1] += " " + trimmed
            }
        }
        return entries
    }

    // MARK: - The repeating schedule

    public static let scheduleWeekdays = "MTWRFSU"

    /// **Firmware, not a helper.** A scheduled power-on is the one route to being reachable that needs nothing on the network: wake-on-LAN is a LAN broadcast and a relayed phone is not on one.
    public static func wakeCommand(hour: Int) -> String {
        "\(pmsetPath) repeat wakeorpoweron \(scheduleWeekdays) \(hourString(hour))"
    }

    /// `cancel`, because `pmset repeat` replaces the pair it is given and no argument means nothing.
    public static let cancelScheduleCommand = "\(pmsetPath) repeat cancel"

    public static func hourString(_ hour: Int) -> String {
        String(format: "%02d:00:00", max(0, min(23, hour)))
    }

    /// **Kept as lines, because the format is not worth parsing.** Filters out `com.apple.` owners; anything unrecognised is offered as written. The header line comes off too.
    public static func otherScheduledEvents(inSchedOutput output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty
                    && !line.contains("com.apple.")
                    && !line.lowercased().hasPrefix("scheduled power events")
            }
    }

    // MARK: - The system's own idle-sleep timer

    /// **`0` means never, and that is a setting rather than a reading.** A Mac told never to idle-sleep does not sleep when the last assertion lets go, so the schedule would run and change nothing visible. The parenthetical is ignored: the number before it is the setting.
    public static func idleSleepMinutes(inPMSetOutput output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "sleep" else { continue }
            return fields.dropFirst().first.flatMap { Int($0) }
        }
        return nil
    }

    // MARK: - The battery

    public enum BatteryState: Equatable, Sendable {
        case onBattery(percent: Int?)
        case onPower(percent: Int?)
        case unknown
    }

    /// The level at which this feature gives up and lets the Mac sleep.
    public static let batteryFloor = 10

    /// Source and percentage are read separately because they fail separately: a desktop prints a source line and no battery line, which is power with no number, not an unknown state.
    public static func batteryState(inPMBattOutput output: String) -> BatteryState {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

        let source: BatteryState
        if lines.contains(where: { $0.contains("'Battery Power'") }) {
            source = .onBattery(percent: nil)
        } else if lines.contains(where: { $0.contains("'AC Power'") }) {
            source = .onPower(percent: nil)
        } else {
            return .unknown
        }

        var percent: Int?
        for line in lines {
            guard let sign = line.firstIndex(of: "%") else { continue }
            let digits = line[..<sign].reversed().prefix { $0.isNumber }.reversed()
            if !digits.isEmpty, let value = Int(String(digits)) {
                percent = value
                break
            }
        }

        switch source {
        case .onBattery: return .onBattery(percent: percent)
        case .onPower: return .onPower(percent: percent)
        case .unknown: return .unknown
        }
    }

    /// Fires while the machine is on its way down: with sleep disabled a Mac shut in a bag runs at full draw until flat. Only on battery, with a number.
    public static func batteryIsLow(_ state: BatteryState) -> Bool {
        guard case .onBattery(let percent) = state, let percent else { return false }
        return percent <= batteryFloor
    }

    // MARK: - What to do at launch

    public enum LaunchAction: Equatable, Sendable {
        case restore
        case reapply
        case keep
        case leaveAlone
        case none
    }

    /// A stale `true` marker would make the next launch read "on, and ours" and the quit path turn somebody else's setting off. Not `.unknown`: unknown is not off.
    public static func shouldForgetOwnership(systemState: SleepDisabledState) -> Bool {
        systemState == .off
    }

    public static func launchAction(
        systemState: SleepDisabledState,
        setByThisApp: Bool,
        isPreferred: Bool
    ) -> LaunchAction {
        switch systemState {
        case .on:
            guard setByThisApp else { return .leaveAlone }
            return isPreferred ? .keep : .restore
        case .off:
            // Regardless of the marker: a clean quit turns the machine off while leaving the switch on, so reopening would otherwise show a switch on and a Mac that sleeps.
            return isPreferred ? .reapply : .none
        case .unknown:
            return .none
        }
    }
}
