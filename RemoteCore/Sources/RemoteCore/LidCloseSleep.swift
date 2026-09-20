import Foundation

/// Keeping a Mac running with its lid shut: the text that grants it, and the decisions around it.
///
/// **Why this is in the shared core and not in the host target.** Nothing else in the codebase has
/// a lid, so on subject matter alone this belongs beside ``HostModel``. It is here for the reason
/// that decides where code goes in this project: whether it can be tested at all. The host target
/// has no test bundle this project can run (see `MacCastKit`'s manifest for why Xcode cannot
/// execute the test action), so a rule about which bytes go into `/etc/sudoers.d` could only be
/// checked by hand, on a real Mac, by someone willing to edit sudoers and find out. Everything
/// here is Foundation and text, which is what makes moving it cost nothing but a longer walk.
///
/// **What the switch actually is.** macOS has no public call that keeps a Mac awake with the lid
/// closed. `pmset -a disablesleep 1` is the only switch that does, it needs administrator rights,
/// and it is a *setting* rather than an assertion: it outlives this process, a crash and a reboot.
/// That last property is the dangerous one, and it is why half of this type is about who turned it
/// on rather than about how to turn it on.
public enum LidCloseSleep {
    /// The path of the command, written the way `sudoers` has to have it.
    ///
    /// Absolute, because a relative or bare name in a sudoers rule means "whatever is on the
    /// command search path", which a user can change.
    public static let pmsetPath = "/usr/bin/pmset"

    /// The one file this app ever has written as root.
    ///
    /// **No dot in the name, and that is a requirement rather than a preference.** `sudo` skips
    /// every file in an include directory whose name contains a `.`, so a name with one would be
    /// a rule that is installed, looks right in `ls`, and does nothing. The staging file below
    /// leans on the same rule in the other direction.
    public static let sudoersPath = "/etc/sudoers.d/peering-sleep"

    /// The command that turns lid-close sleep prevention on or off.
    ///
    /// **`disablesleep` is not a per-source setting, so the `-a` here selects nothing.** That was
    /// worth checking rather than assuming, because the rest of `pmset` splits by power source: the
    /// man page describes `-b`, `-c` and `-a` as choosing battery, charger or all, and a reading of
    /// this feature that took that at face value would expect three shapes of the command and grant
    /// all of them. It does not work that way. `defaults read
    /// /Library/Preferences/com.apple.PowerManagement.plist` shows `SleepDisabled` under
    /// `SystemPowerSettings`, a sibling of the "AC Power" and "Battery Power" dictionaries rather
    /// than a member of either, and `pmset -g custom` does not list it under either source. One
    /// flag, one command per direction.
    ///
    /// The `-a` is kept anyway, and the reason is that it costs nothing: it is true, it reads as
    /// deliberate to anyone who has not done the reading above, and the rule matches on the whole
    /// argv either way. What must not happen is the opposite mistake, granting `-a`, `-b` and `-c`
    /// forms thinking the feature needs them.
    ///
    /// **Undocumented, too.** `disablesleep` does not appear in `man pmset` at all, which is worth
    /// recording here because the comment above would otherwise read as though it came from a
    /// manual page. It is a real key in the power-management plist and a real verb in the binary,
    /// and the whole feature rests on it.
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
    /// **Deliberately narrower than the set of legal account names.** A sudoers line is a small
    /// language of its own: a comma separates commands, `(`, `)` and `:` delimit the run-as part,
    /// `!` negates a rule, `\` escapes the next character, and `#` starts a comment. A name
    /// holding any of those either produces a file `visudo` refuses, which is a machine that
    /// cannot run `sudo` at all until somebody repairs it from Recovery, or produces a line that
    /// parses as something with more reach than one user name. Every account name macOS will
    /// hand this app is letters, digits, `_`, `-` and `.`, so the filter costs nothing real.
    ///
    /// A leading `-` or `.` is rejected as well, because those are how a name reads as an option
    /// or as a hidden file rather than as a person.
    public static func isValidUserName(_ name: String) -> Bool {
        // **`ALL` is the one name the character filter above cannot catch**, because it is spelled
        // with the letters every good name uses. It is also a keyword rather than a person: a rule
        // reading `ALL ALL=(root) NOPASSWD: ...` grants those two root commands to every account on
        // the machine. Rejected case-insensitively, because sudoers reads its keywords that way.
        // Reaching this needs a local account whose short name really is `ALL`, so it is hardening
        // rather than a hole, and one condition is a cheap way to not have to remember that.
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
        /// The account name cannot be written into a sudoers rule.
        ///
        /// Carries the name so the message can show it: this is only ever reached by a user whose
        /// short name contains something unusual, and they are the one person who can tell what
        /// it is.
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
    /// The whole of the promise the settings screen makes: two commands, for one user, as root,
    /// without a password. Nothing here is negotiated at install time or edited afterwards, so
    /// what is written is what can be read in this function.
    ///
    /// **`NOPASSWD:` on commands with their arguments.** `sudo` matches a rule's arguments as well
    /// as its program, and a rule that names arguments matches only those arguments. So this
    /// grants `pmset -a disablesleep 1` and `pmset -a disablesleep 0` and no other use of `pmset`,
    /// and the run-as is `root` rather than `ALL` so the same rule cannot be spent on another
    /// account.
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
    /// **Every step is fatal, and the failure mode is what makes that necessary.** A sudoers file
    /// with a syntax error in it does not break this app: it breaks `sudo` for the whole machine,
    /// including the `sudo` that would be needed to repair it, and the repair is a Recovery boot.
    /// So the text is written somewhere harmless first, checked by `visudo` against the real
    /// grammar, and only then moved into place, and the move is a rename, which is atomic.
    ///
    /// **The dot in the staging name is load-bearing.** `sudo` ignores every file in an include
    /// directory whose name contains a `.`, so a process killed between the write and the rename
    /// leaves behind a file that `sudo` will not read. That is also why the staging file is made
    /// in `/etc/sudoers.d` rather than in `/tmp`: a rename across filesystems copies instead, and
    /// stops being atomic at exactly the moment it matters.
    ///
    /// A failure at any step leaves the machine as it was. The trap removes both temporary files
    /// on the way out, including on the path where `visudo` rejects the text.
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
    /// **Sleep first, then the file.** The two have to happen in this order: the rule is what lets
    /// this app turn the setting off later, so removing it while `disablesleep` is still 1 would
    /// leave a Mac that will not sleep and nothing left to undo it with. Run as root in one
    /// prompt, the pair is also the cheapest way to undo the whole feature: one password, and
    /// nothing of Peering's is left on the machine.
    public static func removeScript() -> String {
        """
        set -e
        \(pmsetPath) -a disablesleep 0
        /bin/rm -f \(quoted(sudoersPath))
        """
    }

    /// An AppleScript that runs a shell script as the administrator.
    ///
    /// `do shell script` is the only route to root that ships with macOS and can be called from a
    /// normal app: it puts up the system's own authentication dialog, and "with administrator
    /// privileges" is what makes the process it starts run as root. The alternative, a privileged
    /// helper installed with `SMJobBless`, is a second binary to sign, notarise and keep in step
    /// with this one, which is a great deal of machinery for two `pmset` calls.
    ///
    /// The prompt is passed rather than left to the default: the system's stock wording says the
    /// app "is trying to make changes", and the point of the prompt is to say which changes.
    public static func administratorScript(shellScript: String, prompt: String) -> String {
        "do shell script \(appleScriptLiteral(shellScript)) with administrator privileges with prompt \(appleScriptLiteral(prompt))"
    }

    /// A string written the way an AppleScript literal holds it.
    ///
    /// Both languages are in play here and they escape different characters, which is the whole
    /// reason this is a function with a test rather than a `replacingOccurrences` at the call
    /// site: the shell script inside the AppleScript holds backslashes of its own from
    /// ``quoted(_:)``, and a rule that gets this wrong runs a *different* script as root.
    ///
    /// Line feeds are written as `\n` rather than left in the literal. AppleScript reads a real
    /// newline inside a string as part of the string, so both work, but only one survives being
    /// read back in a log or a bug report without looking like the line ended there.
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
    /// imported because this one is on the other side of a root prompt: a name that escaped its
    /// quotes here would be a name running as root. Single quotes because inside them a shell
    /// expands nothing, and the one character they cannot hold is closed, escaped and reopened.
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
        /// The line was absent or printed something this does not understand.
        ///
        /// A third answer rather than a guess between the other two, because the two mistakes are
        /// not equal: reading a 1 as "off" would leave a Mac unable to sleep until somebody
        /// noticed, while reading it as "unknown" only means doing nothing and saying so.
        case unknown
    }

    /// Reads `SleepDisabled` out of `pmset -g`.
    ///
    /// Matched on the key rather than on the position, and only in the first column: the same
    /// output carries lines like `sleep 0 (sleep prevented by ...)` whose *value* is a word and
    /// whose key would otherwise match a loose search.
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
    /// **Asked of `sudo` rather than of the disk.** The file cannot be read without being root,
    /// and the question that matters is not "is there a file at that path" but "does `sudo`
    /// honour it": the file could have been replaced, or the include directory turned off in
    /// `/etc/sudoers`. This is also the cheap check, because the answer is already cached by the
    /// system when a command runs a moment later.
    ///
    /// **The listing needs folding before it can be read.** `sudo` wraps a long command list over
    /// several lines, indenting the continuation further, and it wraps between arguments. A check
    /// that reads line by line finds half a command and reports a rule that is working as missing.
    /// So every line that does not begin an entry is joined onto the one before it, and only the
    /// text after `NOPASSWD:` is looked at, split on the commas that separate one command from the
    /// next. A command that is present but negated arrives as `!command`, which is not equal to
    /// `command` and is correctly read as not granted.
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

    /// The listing split into one string per rule, with each rule's wrapped lines joined.
    ///
    /// An entry begins with a run-as specification in brackets, which is what the headers above
    /// them (`Matching Defaults entries for ...`) do not. Anything else is a continuation.
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

    /// The level at which this feature gives up and lets the Mac sleep.
    ///
    /// Ten, which is the same threshold the only other implementation of this on the machine uses.
    /// Late enough to be a real warning rather than a nag, early enough to leave the machine with
    /// something in it.
    public static let batteryFloor = 10

    /// Reads the power source and the charge out of `pmset -g batt`.
    ///
    /// **The source and the percentage are read separately, because they arrive separately and fail
    /// separately.** A desktop Mac prints the source line and no battery line at all, which is a Mac
    /// on power with no number rather than a Mac whose state could not be determined, and the
    /// difference matters: the first is a Mac this feature can never trip on, and the second is one
    /// it must not guess about.
    ///
    /// The percentage is taken as the digits immediately before a `%` rather than by splitting the
    /// line, because the shape of that line differs between a Mac that is charging, one that is
    /// discharging and one that is held at full:
    ///
    ///     Now drawing from 'Battery Power'
    ///      -InternalBattery-0 (id=4653157)	83%; discharging; 3:47 remaining present: true
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
    /// **The one rail this feature has that nothing else covers.** Sleep disabled means the Mac runs
    /// at full draw until the battery is flat, and the Mac most likely to be in that state is the
    /// one shut in a bag with nobody watching it. The quit path and the launch repair both need the
    /// app to run again; this is the only check that fires while the machine is on its way down.
    ///
    /// Only on battery, and only with a number. A Mac on power at 8% is a Mac that is charging, and
    /// a Mac whose charge could not be read is not a Mac to take a decision about.
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
    /// **The whole reason this is a value with a test.** A crash cannot run any cleanup code, and
    /// `disablesleep` survives a crash, so the state a host wakes up to is not necessarily the
    /// state it went to sleep with. The three inputs are: what `pmset -g` reports, whether this
    /// app wrote down that it was the one to turn the setting on, and whether the user's switch is
    /// on now.
    ///
    /// The rule that must not be got wrong is the second one: **a machine that has sleep disabled
    /// without our marker is somebody else's doing**, and undoing it would be this app overriding
    /// a decision it knows nothing about. That case is reported rather than acted on, which is the
    /// whole difference between adopting a setting and stealing one.
    ///
    /// The marker is also what makes the quit-time restore safe to keep: a Mac whose sleep was
    /// disabled by another tool must not have it re-enabled every time Peering quits.
    /// Whether the marker should be dropped, given what the machine reads.
    ///
    /// **The marker is a claim about a setting that is no longer there.** It is written when this
    /// app turns `disablesleep` on and cleared on the paths that turn it off, and a crash or a
    /// force quit skips those. A stale `true` is not harmless: if somebody else then sets the
    /// setting, the next launch reads "on, and ours", and the quit path turns their setting off.
    /// Nothing else consults the marker, so clearing it whenever the machine reads `.off` costs
    /// nothing and closes that sequence.
    ///
    /// Not `.unknown`: "we could not tell" is not "it is off", and forgetting ownership on a
    /// reading that failed is how a Mac ends up unable to sleep with nothing left claiming it.
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
            // Regardless of the marker, because a clean quit turns the machine back off while
            // leaving the switch on: without this, reopening the app would show a switch that was
            // on and a Mac that slept on the next closed lid.
            return isPreferred ? .reapply : .none
        case .unknown:
            return .none
        }
    }
}
