import Foundation

/// Keeping a Mac running with its lid shut: the text that grants it, and the decisions around it.
///
/// macOS has no public call that keeps a Mac awake with the lid closed. `pmset -a disablesleep 1`
/// is the only switch that does, it needs administrator rights, and it is a setting rather than an
/// assertion: it outlives this process, a crash and a reboot.
public enum LidCloseSleep {
    /// The path of the command, written the way `sudoers` has to have it: absolute, because a bare
    /// name in a sudoers rule means whatever is on the command search path, which a user can change.
    public static let pmsetPath = "/usr/bin/pmset"

    /// The one file this app ever has written as root.
    ///
    /// No dot in the name: `sudo` skips every file in an include directory whose name contains a
    /// `.`, so a name with one would be a rule that looks right and does nothing.
    public static let sudoersPath = "/etc/sudoers.d/peering-sleep"

    /// The command that turns lid-close sleep prevention on or off.
    ///
    /// `disablesleep` is not a per-source setting, so the `-a` selects nothing, and the key does
    /// not appear in `man pmset` at all even though the whole feature rests on it.
    public static func command(disabled: Bool) -> String {
        "\(pmsetPath) -a disablesleep \(disabled ? "1" : "0")"
    }

    /// The two commands a correct rule grants, and the whole of what it grants.
    public static var grantedCommands: [String] {
        [command(disabled: true), command(disabled: false)]
    }

    // MARK: - Who the rule is for

    /// Whether a name can be written into a sudoers rule as a user.
    ///
    /// Deliberately narrower than the set of legal account names: a sudoers line is a small
    /// language, where a comma separates commands, `(`, `)` and `:` delimit the run-as part, `!`
    /// negates, `\` escapes, and `#` starts a comment. A name holding any of those either produces
    /// a file `visudo` refuses, which breaks `sudo` for the whole machine, or parses as something
    /// with more reach than one user name.
    public static func isValidUserName(_ name: String) -> Bool {
        // `ALL` passes the character filter and is a sudoers keyword rather than a person:
        // `ALL ALL=(root) NOPASSWD: ...` would grant those commands to every account on the machine.
        // Rejected case-insensitively, because sudoers reads its keywords that way.
        guard name.uppercased() != "ALL" else { return false }

        guard let first = name.first, first.isLetter || first.isNumber || first == "_" else {
            return false
        }
        return name.allSatisfy { character in
            character.isLetter || character.isNumber
                || character == "_" || character == "-" || character == "."
        }
    }

    /// What can go wrong while composing the rule.
    public enum RuleError: Error, Equatable, LocalizedError {
        /// The account name cannot be written into a sudoers rule. Carries the name so the message
        /// can show it.
        case unusableUserName(String)

        public var errorDescription: String? {
            switch self {
            case .unusableUserName(let name):
                return "Peering will not write an administrator rule for the account \"\(name)\", because its name cannot be spelled safely in one."
            }
        }
    }

    // MARK: - The sudoers file

    /// The exact contents of the drop-in.
    ///
    /// `NOPASSWD:` on commands that carry their arguments: `sudo` matches a rule's arguments as
    /// well as its program, so this grants the two `pmset` commands and no other use of `pmset`.
    /// The run-as is `root` rather than `ALL`, so the rule cannot be spent on another account.
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

    /// The shell script the administrator prompt runs to install the rule.
    ///
    /// Every step is fatal, because a sudoers file with a syntax error breaks `sudo` for the whole
    /// machine and the repair is a Recovery boot. So the text is written elsewhere first, checked
    /// by `visudo`, then moved in by an atomic rename.
    ///
    /// The dot in the staging name is load-bearing: `sudo` ignores every file in an include
    /// directory whose name contains a `.`, so a process killed before the rename leaves a file
    /// `sudo` will not read. Staging in `/etc/sudoers.d` rather than `/tmp` keeps the rename on one
    /// filesystem.
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

    /// The shell script the administrator prompt runs to take the rule away again.
    ///
    /// Sleep first, then the file: the rule is what lets this app turn the setting off later, so
    /// removing it while `disablesleep` is still 1 would leave a Mac that will not sleep and
    /// nothing left to undo it.
    public static func removeScript() -> String {
        """
        set -e
        \(pmsetPath) -a disablesleep 0
        /bin/rm -f \(quoted(sudoersPath))
        """
    }

    /// An AppleScript that runs a shell script as the administrator.
    ///
    /// `do shell script ... with administrator privileges` is the only route to root that ships
    /// with macOS, and it puts up the system's own authentication dialog. The prompt is passed
    /// rather than left to the default, which does not say which changes are being made.
    public static func administratorScript(shellScript: String, prompt: String) -> String {
        "do shell script \(appleScriptLiteral(shellScript)) with administrator privileges with prompt \(appleScriptLiteral(prompt))"
    }

    /// A string written the way an AppleScript literal holds it.
    ///
    /// The shell script inside it holds backslashes of its own from ``quoted(_:)``, and getting
    /// this wrong runs a different script as root.
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

    /// A string written the way a shell reads it back as one word.
    ///
    /// The same rule the app's terminals use (see ``ShellPath/quoted(_:)``), repeated rather than
    /// imported because this one is on the other side of a root prompt.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Reading the machine

    /// What `SleepDisabled` says in `pmset -g`.
    public enum SleepDisabledState: Equatable, Sendable {
        /// `SleepDisabled 1`: this Mac will not sleep on a closed lid.
        case on
        /// `SleepDisabled 0`: it will.
        case off
        /// The line was absent or printed something this does not understand. A third answer rather
        /// than a guess: reading a 1 as "off" would leave a Mac unable to sleep.
        case unknown
    }

    /// Reads `SleepDisabled` out of `pmset -g`.
    ///
    /// Matched on the key, in the first column, because the output also carries lines like
    /// `sleep 0 (sleep prevented by ...)`.
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

    /// Which of the two commands `sudo -n -l` says may be run without a password.
    public struct Grants: Equatable, Sendable {
        public var disablesSleepOn: Bool
        public var disablesSleepOff: Bool

        /// Whether the drop-in is in place and doing its job.
        public var coversBoth: Bool { disablesSleepOn && disablesSleepOff }

        public init(disablesSleepOn: Bool = false, disablesSleepOff: Bool = false) {
            self.disablesSleepOn = disablesSleepOn
            self.disablesSleepOff = disablesSleepOff
        }
    }

    /// Reads the two commands out of the listing `sudo -n -l` prints.
    ///
    /// Asked of `sudo` rather than of the disk: the file cannot be read without being root, and the
    /// question is not "is there a file at that path" but "does `sudo` honour it". The listing wraps
    /// long command lists between arguments, so lines that do not begin an entry are joined on.
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

    /// The listing split into one string per rule, with each rule's wrapped lines joined. An entry
    /// begins with a run-as specification in brackets; anything else is a continuation.
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

    // MARK: - The battery

    /// What `pmset -g batt` says about where the power is coming from.
    public enum BatteryState: Equatable, Sendable {
        case onBattery(percent: Int?)
        case onPower(percent: Int?)
        /// Neither line was there, or neither said anything this understands.
        case unknown
    }

    /// The level at which this feature gives up and lets the Mac sleep: the same threshold the only
    /// other implementation of this on the machine uses.
    public static let batteryFloor = 10

    /// Reads the power source and the charge out of `pmset -g batt`.
    ///
    /// The source and the percentage are read separately, because they fail separately: a desktop
    /// Mac prints the source line and no battery line at all, which is a Mac on power with no
    /// number rather than one whose state could not be determined. The percentage is the digits
    /// immediately before a `%`.
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

    /// Whether the battery has fallen far enough that keeping the Mac up is the wrong trade.
    ///
    /// The one rail that fires while the machine is on its way down: sleep disabled means the Mac
    /// runs at full draw until the battery is flat, and the Mac most likely to be in that state is
    /// shut in a bag with nobody watching. Only on battery, with a number.
    public static func batteryIsLow(_ state: BatteryState) -> Bool {
        guard case .onBattery(let percent) = state, let percent else { return false }
        return percent <= batteryFloor
    }

    // MARK: - What to do at launch

    /// What a launch should do about a setting that outlives the process.
    public enum LaunchAction: Equatable, Sendable {
        /// We turned it on, the switch is off now: turn the machine back on with it.
        case restore
        /// The switch is on and the machine has lost the setting: turn it on again.
        case reapply
        /// On, wanted, and ours. Nothing to do.
        case keep
        /// On, and not ours. Leave it alone and say so.
        case leaveAlone
        /// Nothing to do.
        case none
    }

    /// What to do about `disablesleep` at launch, given what the machine says and what this app
    /// remembers.
    ///
    /// A crash cannot run cleanup code, and `disablesleep` survives a crash, so the state a host
    /// wakes up to is not necessarily the state it went to sleep with. A machine with sleep
    /// disabled and no marker of ours is somebody else's doing, so it is reported rather than acted
    /// on, and the marker is also what makes the quit-time restore safe.
    /// Whether the marker should be dropped, given what the machine reads.
    ///
    /// The marker is a claim about a setting that may no longer be there: a crash or force quit
    /// skips the paths that clear it, and a stale `true` would let the next launch read "on, and
    /// ours" and the quit path turn somebody else's setting off. Not `.unknown`: "we could not
    /// tell" is not "it is off".
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
            // Regardless of the marker: a clean quit turns the machine back off while leaving the
            // switch on, so without this, reopening the app would show a switch that is on and a
            // Mac that sleeps on the next closed lid.
            return isPreferred ? .reapply : .none
        case .unknown:
            return .none
        }
    }
}
