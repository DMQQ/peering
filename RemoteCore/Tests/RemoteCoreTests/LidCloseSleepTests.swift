import Foundation
import Testing

@testable import RemoteCore

@Suite("Lid-close sleep")
struct LidCloseSleepTests {

    // MARK: - Reading pmset

    /// Real output from a Mac with the setting off; the same listing has `sleep 0 (sleep prevented by ...)`, whose key starts with the same word.
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

    /// Both must be unknown rather than off: reading a 1 as off leaves a Mac that never sleeps with nothing on screen to explain it.
    @Test("a missing line and a value that makes no sense are both unknown")
    func readsUnknown() {
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: "System-wide power settings:\n sleep 0\n") == .unknown)
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: " SleepDisabled 2\n") == .unknown)
        #expect(LidCloseSleep.sleepDisabledState(inPMSetOutput: "") == .unknown)
    }

    /// Only the first two columns count: `sleep 0 (sleep prevented by SleepDisabled ...)` must not be read as the setting.
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
        for line in text.split(separator: "\n") where !line.isEmpty && !line.hasPrefix("#") {
            #expect(line == "dmq ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
        }
        #expect(text.hasSuffix("disablesleep 0\n"))
    }

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

    @Test("the install validates before it installs, and installs in one move")
    func installScript() throws {
        let script = try LidCloseSleep.installScript(user: "dmq")

        #expect(script.contains("/usr/sbin/visudo -cf \"$checked\""))
        // The whole line: a substring check passes when the source, destination or binary is wrong.
        #expect(script.contains("/usr/bin/install -o root -g wheel -m 0440 \"$checked\" \"$staged\""))
        #expect(script.contains("/bin/mv -f \"$staged\" '/etc/sudoers.d/peering-sleep'"))
        #expect(script.hasPrefix("set -e\n"))
        #expect(script.contains("trap '/bin/rm -f \"$checked\" \"$staged\"' EXIT"))
        // The staging name contains dots, which is what makes `sudo` ignore it if this process
        // dies between the write and the move.
        #expect(script.contains("/etc/sudoers.d/.peering-sleep.new"))
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

    /// A shell script inside an AppleScript: wrong escaping runs a different script as root.
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

    /// A real listing: `(ALL) ALL` plus another tool's clamshell rule. Neither is ours, so nothing of ours is installed.
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

    /// Wrapped the way `sudo` wraps a long command list; reading line by line finds half a command.
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

    /// A desktop prints the source and nothing else: `onPower` with no number, not `unknown`.
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

    @Test("the launch decision")
    func launchActions() {
        #expect(LidCloseSleep.launchAction(systemState: .on, setByThisApp: true, isPreferred: true) == .keep)
        // Ours, and the switch is off now: this is a crash between turning it on and cleaning up.
        #expect(LidCloseSleep.launchAction(systemState: .on, setByThisApp: true, isPreferred: false) == .restore)
        #expect(LidCloseSleep.launchAction(systemState: .on, setByThisApp: false, isPreferred: true) == .leaveAlone)
        #expect(LidCloseSleep.launchAction(systemState: .on, setByThisApp: false, isPreferred: false) == .leaveAlone)
        #expect(LidCloseSleep.launchAction(systemState: .off, setByThisApp: true, isPreferred: true) == .reapply)
        #expect(LidCloseSleep.launchAction(systemState: .off, setByThisApp: false, isPreferred: true) == .reapply)
        #expect(LidCloseSleep.launchAction(systemState: .off, setByThisApp: false, isPreferred: false) == .none)
        #expect(LidCloseSleep.launchAction(systemState: .off, setByThisApp: true, isPreferred: false) == .none)
        #expect(LidCloseSleep.launchAction(systemState: .unknown, setByThisApp: true, isPreferred: false) == .none)
        #expect(LidCloseSleep.launchAction(systemState: .unknown, setByThisApp: true, isPreferred: true) == .none)
        #expect(LidCloseSleep.launchAction(systemState: .unknown, setByThisApp: false, isPreferred: true) == .none)
    }

    @Test("nothing is ever undone without the marker")
    func neverUndoneWithoutTheMarker() {
        for state in [LidCloseSleep.SleepDisabledState.on, .off, .unknown] {
            for preferred in [true, false] {
                let action = LidCloseSleep.launchAction(systemState: state, setByThisApp: false, isPreferred: preferred)
                #expect(action != .restore)
            }
        }
    }

    /// Ownership is dropped only on `off`, never `.unknown`: a failed read is not `off`, and dropping it leaves a Mac unable to sleep.
    @Test("ownership is forgotten only on a reading of off")
    func forgettingOwnership() {
        #expect(LidCloseSleep.shouldForgetOwnership(systemState: .off))
        #expect(LidCloseSleep.shouldForgetOwnership(systemState: .on) == false)
        #expect(LidCloseSleep.shouldForgetOwnership(systemState: .unknown) == false)
    }

    /// `ALL` is a sudoers keyword (case-insensitive) that would grant both root commands to every account; the character filter cannot catch it.
    @Test("the sudoers keyword is not an account name")
    func theKeywordIsRefused() throws {
        #expect(LidCloseSleep.isValidUserName("ALL") == false)
        #expect(LidCloseSleep.isValidUserName("all") == false)
        #expect(LidCloseSleep.isValidUserName("All") == false)
        #expect(throws: LidCloseSleep.RuleError.unusableUserName("ALL")) {
            try LidCloseSleep.sudoersFileText(user: "ALL")
        }
        #expect(LidCloseSleep.isValidUserName("ALLEN"))
        #expect(LidCloseSleep.isValidUserName("AL"))
        #expect(LidCloseSleep.isValidUserName("allan"))
    }

    /// An administrator's listing: the blanket `(ALL) ALL` plus one scoped rule. Merging entries in continuation folding would read someone else's `(ALL) ALL` as ours.
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
        // No dot in the file name: `sudo` skips dotted entries, so such a rule looks right in `ls` and does nothing.
        #expect(LidCloseSleep.sudoersPath == "/etc/sudoers.d/peering-sleep")
    }
}
