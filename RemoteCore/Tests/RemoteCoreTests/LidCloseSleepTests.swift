import Foundation
import Testing

@testable import RemoteCore

/// Keeping a Mac awake with its lid shut, and knowing who asked for it.
///
/// **Why these are worth having at all.** Three of the four things below are read or written by
/// something outside this app: `pmset` prints the setting, `sudo` prints the rule it is honouring,
/// and the only way to check either by hand is on a Mac that is willing to have its `/etc/sudoers.d`
/// edited. The fourth, what a launch should do about a setting that survived a crash, cannot be
/// checked by hand at all without arranging a crash first.
@Suite("Lid-close sleep")
struct LidCloseSleepTests {

    // MARK: - Reading pmset

    /// Real output, taken from a Mac on which the setting is off, which is what the parse has to
    /// survive first: the same listing carries `sleep 0 (sleep prevented by ...)`, a line whose
    /// key begins with the same word and whose value is a sentence.
    private let pmsetOff = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             1
     networkoversleep     0
     disksleep            10
     sleep                0 (sleep prevented by caffeinate, powerd, sharingd)
     hibernatemode        3
     ttyskeepawake        1
     displaysleep         30 (display sleep prevented by Peering)
     tcpkeepalive         1
     lowpowermode         0
     womp                 1
    """

    @Test("a Mac that sleeps on its lid reads as off")
    func readsOff() {
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: pmsetOff) == .off)
    }

    @Test("a Mac that does not reads as on")
    func readsOn() {
        let text = pmsetOff.replacingOccurrences(of: " SleepDisabled\t\t0", with: " SleepDisabled\t\t1")
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: text) == .on)
    }

    /// The line is absent on some machines and in some versions, and a value that is neither 0 nor
    /// 1 is not a thing `pmset` prints on purpose. Both have to be unknown rather than off: the
    /// two mistakes are not equal, because reading a 1 as off leaves a Mac that never sleeps with
    /// nothing on screen to explain it.
    @Test("a missing line and a value that makes no sense are both unknown")
    func readsUnknown() {
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: "System-wide power settings:\n sleep 0\n") == .unknown)
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: " SleepDisabled 2\n") == .unknown)
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: "") == .unknown)
    }

    /// The key and the value have to be in the first two columns. `sleep 0 (sleep prevented by
    /// SleepDisabled ...)` is a line this parse must not read as the setting, and the same test
    /// catches a line where the word appears anywhere else.
    @Test("the key is only read in the first column")
    func readsOnlyTheKey() {
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: " sleep 0 (disablesleep 1)\n") == .unknown)
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: " note SleepDisabled 1\n") == .unknown)
    }

    // MARK: - The rule

    @Test("the rule is one user, two commands, no password")
    func sudoersText() throws {
        let text = try LidCloseSleep.sudoersFileText(user: "dmq")
        #expect(text.contains("dmq ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"))
        // The whole of what the file grants is the line above: anything else in it is a comment.
        for line in text.split(separator: "\n") where !line.isEmpty && !line.hasPrefix("#") {
            #expect(line == "dmq ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
        }
        // sudoers wants a newline at the end, and this asserts it against the last rule rather
        // than against a blank line, which is the sort of thing a later edit removes quietly.
        #expect(text.hasSuffix("disablesleep 0\n"))
    }

    /// A name is the one part of that line the app does not choose, and it is the part that could
    /// turn a rule for two commands into a rule for something else. `visudo` refusing the file is
    /// the good outcome; a line that parses as more than one user is the bad one.
    @Test("a name that could mean something else is refused")
    func names() throws {
        #expect(LidCloseSleep.isValidUserName("dmq"))
        #expect(LidCloseSleep.isValidUserName("damian.derlecki"))
        #expect(LidCloseSleep.isValidUserName("build_agent-2"))

        #expect(LidCloseSleep.isValidUserName("") == false)
        #expect(LidCloseSleep.isValidUserName("dmq,root") == false)
        #expect(LidCloseSleep.isValidUserName("dmq root") == false)
        #expect(LidCloseSleep.isValidUserName("%admin") == false)
        #expect(LidCloseSleep.isValidUserName("dmq) NOPASSWD: ALL #") == false)
        #expect(LidCloseSleep.isValidUserName("-o") == false)
        #expect(LidCloseSleep.isValidUserName(".hidden") == false)
        #expect(LidCloseSleep.isValidUserName("dmq\nroot") == false)
        #expect(LidCloseSleep.isValidUserName("dmq\\") == false)

        #expect(throws: LidCloseSleep.RuleError.unusableUserName("dmq,root")) {
            try LidCloseSleep.sudoersFileText(user: "dmq,root")
        }
        #expect(throws: LidCloseSleep.RuleError.unusableUserName("dmq,root")) {
            try LidCloseSleep.installScript(user: "dmq,root")
        }
    }

    /// The install is checked before it is installed, and the checks that matter are the ones that
    /// keep a bad file out of `/etc/sudoers.d`: the validation step, the mode, and the fact that
    /// the file lands in one move rather than in pieces.
    @Test("the install validates before it installs, and installs in one move")
    func installScript() throws {
        let script = try LidCloseSleep.installScript(user: "dmq")

        #expect(script.contains("/usr/sbin/visudo -cf \"$checked\""))
        // The whole line rather than a fragment of it. A substring check for the mode and owner
        // passes just as well when the source, the destination or the binary is wrong, and this is
        // the one line in the file that decides where a root-owned file ends up.
        #expect(script.contains("/usr/bin/install -o root -g wheel -m 0440 \"$checked\" \"$staged\""))
        #expect(script.contains("/bin/mv -f \"$staged\" '/etc/sudoers.d/peering-sleep'"))
        // Fatal at every step, and cleaned up on the way out however it ends.
        #expect(script.hasPrefix("set -e\n"))
        #expect(script.contains("trap '/bin/rm -f \"$checked\" \"$staged\"' EXIT"))
        // The staging name contains dots, which is what makes `sudo` ignore it if this process
        // dies between the write and the move.
        #expect(script.contains("/etc/sudoers.d/.peering-sleep.new"))
        // The validation happens before anything is put where `sudo` reads it.
        #expect(script.range(of: "visudo -cf")!.lowerBound < script.range(of: "-o root -g wheel")!.lowerBound)
    }

    @Test("removing the rule lets the Mac sleep first, in the same script")
    func removeScript() {
        let script = LidCloseSleep.removeScript()
        #expect(script.hasPrefix("set -e\n"))
        #expect(script.contains("/usr/bin/pmset -a disablesleep 0"))
        #expect(script.contains("/bin/rm -f '/etc/sudoers.d/peering-sleep'"))
        // Sleep first: the rule is what lets the app turn that setting off later, so a script that
        // removed it first would leave a Mac that cannot sleep with nothing left to undo it.
        #expect(script.range(of: "disablesleep 0")!.lowerBound < script.range(of: "rm -f")!.lowerBound)
    }

    // MARK: - Quoting

    /// Both languages are in play in one string: a shell script inside an AppleScript. Getting the
    /// escaping wrong does not produce an error, it produces a different script running as root.
    @Test("a shell script survives being put inside an AppleScript")
    func appleScriptQuoting() {
        #expect(LidCloseSleep.appleScriptLiteral("plain") == "\"plain\"")
        #expect(LidCloseSleep.appleScriptLiteral("a \"quoted\" word") == "\"a \\\"quoted\\\" word\"")
        #expect(LidCloseSleep.appleScriptLiteral("print '\\''") == "\"print '\\\\''\"")
        #expect(LidCloseSleep.appleScriptLiteral("one\ntwo") == "\"one\\ntwo\"")

        let script = LidCloseSleep.administratorScript(shellScript: "echo hi", prompt: "Say hi")
        #expect(script == "do shell script \"echo hi\" with administrator privileges with prompt \"Say hi\"")
    }

    @Test("a path with a quote in it stays one word")
    func shellQuoting() {
        #expect(LidCloseSleep.quoted("/etc/sudoers.d/peering-sleep") == "'/etc/sudoers.d/peering-sleep'")
        #expect(LidCloseSleep.quoted("Peering's Mac") == "'Peering'\\''s Mac'")
    }

    // MARK: - Reading the rule back

    /// A real listing, from a Mac whose admin account has `(ALL) ALL` and one other tool's clamshell
    /// rule in `/etc/sudoers.d`. Neither of those is this app's, and neither grants the `-a` form,
    /// so the answer here has to be that nothing of ours is installed.
    private let otherToolsListing = """
    Matching Defaults entries for dmq on Damians-MacBook-Pro:
        env_reset, env_keep+=BLOCKSIZE, env_keep+="COLORFGBG COLORTERM",
        env_keep+=__CF_USER_TEXT_ENCODING, env_keep+="CHARSET LANG LANGUAGE LC_ALL
        LC_COLLATE LC_CTYPE", env_keep+="LC_MESSAGES LC_MONETARY LC_NUMERIC
        LC_TIME", env_keep+="LINES COLUMNS", env_keep+=LSCOLORS,
        env_keep+=SSH_AUTH_SOCK, env_keep+=TZ, env_keep+="DISPLAY XAUTHORIZATION
        XAUTHORITY", env_keep+="EDITOR VISUAL", env_keep+="HOME MAIL",
        lecture_file=/etc/sudo_lecture, !log_allowed

    User dmq may run the following commands on Damians-MacBook-Pro:
        (ALL) ALL
        (root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep
            0
    """

    @Test("another tool's rule is not this app's rule")
    func otherTools() {
        let grants = LidCloseSleep.grants(inSudoListing: otherToolsListing)
        #expect(grants.disablesSleepOn == false)
        #expect(grants.disablesSleepOff == false)
        #expect(grants.coversBoth == false)
    }

    /// The same listing with our rule in it, wrapped exactly the way `sudo` wraps a long command
    /// list. Reading it line by line finds half a command, which is the bug this folds away.
    @Test("a wrapped rule is still read")
    func wrapped() {
        let listing = """
        User dmq may run the following commands on Damians-MacBook-Pro:
            (root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep
                0
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep
                0
        """
        let grants = LidCloseSleep.grants(inSudoListing: listing)
        #expect(grants.disablesSleepOn)
        #expect(grants.disablesSleepOff)
        #expect(grants.coversBoth)
    }

    @Test("one command of the two is not enough")
    func halfTheRule() {
        let listing = """
        User dmq may run the following commands on this Mac:
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
        """
        #expect(LidCloseSleep.grants(inSudoListing: listing).coversBoth == false)
    }

    /// A rule that requires a password, or that takes the permission away again, is not the rule
    /// this app installs, and the row must not say it is.
    @Test("a password-protected or negated command is not granted")
    func notGranted() {
        let withPassword = """
        User dmq may run the following commands on this Mac:
            (root) PASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
        """
        #expect(LidCloseSleep.grants(inSudoListing: withPassword).coversBoth == false)

        let negated = """
        User dmq may run the following commands on this Mac:
            (root) NOPASSWD: !/usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
        """
        let grants = LidCloseSleep.grants(inSudoListing: negated)
        #expect(grants.disablesSleepOn == false)
        #expect(grants.disablesSleepOff)
    }

    @Test("a listing that says nothing grants nothing")
    func emptyListing() {
        #expect(LidCloseSleep.grants(inSudoListing: "").coversBoth == false)
        #expect(LidCloseSleep.grants(inSudoListing: "sudo: a password is required\n").coversBoth == false)
    }

    // MARK: - The battery

    /// Real output from a laptop running on its battery.
    private let battOnBattery = """
    Now drawing from 'Battery Power'
     -InternalBattery-0 (id=4653157)\t83%; discharging; 3:47 remaining present: true
    """

    @Test("a laptop on battery reads as on battery, with its charge")
    func readsBattery() {
        #expect(LidCloseSleep.batteryState(inPMBattOutput: battOnBattery) == .onBattery(percent: 83))
    }

    @Test("the same laptop plugged in reads as on power")
    func readsPower() {
        let text = battOnBattery
            .replacingOccurrences(of: "'Battery Power'", with: "'AC Power'")
            .replacingOccurrences(of: "discharging", with: "charging")
        #expect(LidCloseSleep.batteryState(inPMBattOutput: text) == .onPower(percent: 83))
    }

    /// **A desktop Mac prints the source and nothing else.** That is a Mac this feature can never
    /// trip on, which is a fact about the machine rather than a failure to read it, and the two
    /// have to be told apart: one is `onPower` with no number and the other is `unknown`.
    @Test("a Mac with no battery in it is on power, with no number")
    func desktopMac() {
        #expect(
            LidCloseSleep.batteryState(inPMBattOutput: "Now drawing from 'AC Power'\n")
                == .onPower(percent: nil)
        )
    }

    @Test("output that says nothing useful is unknown")
    func unreadableBattery() {
        #expect(LidCloseSleep.batteryState(inPMBattOutput: "") == .unknown)
        #expect(LidCloseSleep.batteryState(inPMBattOutput: "Now drawing from 'UPS Power'\n") == .unknown)
        #expect(LidCloseSleep.batteryState(inPMBattOutput: "Now drawing from 'Battery Power'\n") == .onBattery(percent: nil))
    }

    /// The whole of the watchdog's decision, and the two mistakes it must not make: firing on a Mac
    /// that is plugged in, and firing on a Mac whose charge could not be read.
    @Test("only a nearly flat battery on battery power trips the watchdog")
    func batteryFloor() {
        #expect(LidCloseSleep.batteryIsLow(.onBattery(percent: 10)))
        #expect(LidCloseSleep.batteryIsLow(.onBattery(percent: 9)))
        #expect(LidCloseSleep.batteryIsLow(.onBattery(percent: 11)) == false)
        #expect(LidCloseSleep.batteryIsLow(.onPower(percent: 4)) == false)
        #expect(LidCloseSleep.batteryIsLow(.onPower(percent: nil)) == false)
        #expect(LidCloseSleep.batteryIsLow(.onBattery(percent: nil)) == false)
        #expect(LidCloseSleep.batteryIsLow(.unknown) == false)
    }

    // MARK: - What to do at launch

    /// The table, in one place, because the whole point of the decision is which of these seven
    /// combinations is which.
    @Test("the launch decision")
    func launchActions() {
        // Ours, and still wanted.
        #expect(LidCloseSleep.launchAction(systemState: .on, setByThisApp: true, isPreferred: true) == .keep)
        // Ours, and the switch is off now: this is a crash between turning it on and cleaning up.
        #expect(LidCloseSleep.launchAction(systemState: .on, setByThisApp: true, isPreferred: false) == .restore)
        // Somebody else's, both ways. Left alone, and reported.
        #expect(LidCloseSleep.launchAction(systemState: .on, setByThisApp: false, isPreferred: true) == .leaveAlone)
        #expect(LidCloseSleep.launchAction(systemState: .on, setByThisApp: false, isPreferred: false) == .leaveAlone)
        // Wanted and not in force, which is what a clean quit leaves behind when the switch stays on.
        #expect(LidCloseSleep.launchAction(systemState: .off, setByThisApp: true, isPreferred: true) == .reapply)
        #expect(LidCloseSleep.launchAction(systemState: .off, setByThisApp: false, isPreferred: true) == .reapply)
        // Not wanted, and not set. The ordinary launch.
        #expect(LidCloseSleep.launchAction(systemState: .off, setByThisApp: false, isPreferred: false) == .none)
        #expect(LidCloseSleep.launchAction(systemState: .off, setByThisApp: true, isPreferred: false) == .none)
        // Nothing readable, nothing done. Being wrong here is the expensive direction.
        #expect(LidCloseSleep.launchAction(systemState: .unknown, setByThisApp: true, isPreferred: false) == .none)
        #expect(LidCloseSleep.launchAction(systemState: .unknown, setByThisApp: true, isPreferred: true) == .none)
        #expect(LidCloseSleep.launchAction(systemState: .unknown, setByThisApp: false, isPreferred: true) == .none)
    }

    /// The two paths that change the machine have to be told apart from the three that do not: a
    /// Mac whose sleep was disabled by another tool must not have it switched back on every time
    /// this app quits, and that is what the marker in the table above buys.
    @Test("nothing is ever undone without the marker")
    func neverUndoneWithoutTheMarker() {
        for state in [LidCloseSleep.SleepDisabledState.on, .off, .unknown] {
            for preferred in [true, false] {
                let action = LidCloseSleep.launchAction(systemState: state, setByThisApp: false, isPreferred: preferred)
                #expect(action != .restore)
            }
        }
    }

    /// The marker is this app's claim to have set the setting, and a reading of `off` is where that
    /// claim stops being true. Kept off `.unknown` deliberately: a reading that failed is not a
    /// reading of `off`, and dropping ownership because the question could not be answered is how a
    /// Mac ends up unable to sleep with nothing left that says it should be put back.
    @Test("ownership is forgotten only on a reading of off")
    func forgettingOwnership() {
        #expect(LidCloseSleep.shouldForgetOwnership(systemState: .off))
        #expect(LidCloseSleep.shouldForgetOwnership(systemState: .on) == false)
        #expect(LidCloseSleep.shouldForgetOwnership(systemState: .unknown) == false)
    }

    /// `ALL` is spelled with the letters every good account name uses, so the character filter
    /// cannot catch it, and it is a keyword rather than a person: `ALL ALL=(root) NOPASSWD: ...`
    /// grants those two root commands to every account on the machine. Case-insensitively, because
    /// that is how sudoers reads its keywords.
    @Test("the sudoers keyword is not an account name")
    func theKeywordIsRefused() throws {
        #expect(LidCloseSleep.isValidUserName("ALL") == false)
        #expect(LidCloseSleep.isValidUserName("all") == false)
        #expect(LidCloseSleep.isValidUserName("All") == false)
        #expect(throws: LidCloseSleep.RuleError.unusableUserName("ALL")) {
            try LidCloseSleep.sudoersFileText(user: "ALL")
        }
        // The near misses stay legal: these are account names, not the keyword.
        #expect(LidCloseSleep.isValidUserName("ALLEN"))
        #expect(LidCloseSleep.isValidUserName("AL"))
        #expect(LidCloseSleep.isValidUserName("allan"))
    }

    /// The two entries an administrator's own listing really carries: the blanket `(ALL) ALL` that
    /// makes them an administrator, and one scoped rule. The test above covers a listing with a
    /// *different tool's* rule in it; this one covers the shape that would break if the continuation
    /// folding ever merged two entries into one, which is the failure that would read somebody
    /// else's `(ALL) ALL` as ours.
    @Test("a blanket rule above ours is not folded into it")
    func blanketRuleIsNotOurs() {
        let listing = """
        User dmq may run the following commands on Damians-MacBook-Pro:
            (ALL) ALL
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep \
        0
        """
        let grants = LidCloseSleep.grants(inSudoListing: listing)
        #expect(grants.coversBoth)

        // And the same listing with ours missing is not read as granted just because `(ALL) ALL`
        // is there, which is the failure the fold would produce.
        let onlyBlanket = """
        User dmq may run the following commands on Damians-MacBook-Pro:
            (ALL) ALL
        """
        #expect(LidCloseSleep.grants(inSudoListing: onlyBlanket).coversBoth == false)
    }

    @Test("the commands are the two the switch uses")
    func commands() {
        #expect(LidCloseSleep.command(disabled: true) == "/usr/bin/pmset -a disablesleep 1")
        #expect(LidCloseSleep.command(disabled: false) == "/usr/bin/pmset -a disablesleep 0")
        #expect(LidCloseSleep.grantedCommands == [
            "/usr/bin/pmset -a disablesleep 1",
            "/usr/bin/pmset -a disablesleep 0",
        ])
        // The file's own name has no dot in it: `sudo` skips any entry in an include directory
        // whose name contains one, so a dotted name would be a rule that is installed, looks right
        // in `ls`, and does nothing. (The directory is `/etc/sudoers.d`, which is where the dot
        // belongs.)
        #expect(LidCloseSleep.sudoersPath == "/etc/sudoers.d/peering-sleep")
    }
}
