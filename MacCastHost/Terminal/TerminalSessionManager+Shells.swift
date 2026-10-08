import Darwin
import Foundation
import RemoteCore
import os

extension TerminalSessionManager {
    func create(ownerClientID: String, sink: @escaping Sink) {
        let id = UUID()
        let name = lock.withLock { unusedTerminalName() }
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var size = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else {
            sink(.failed(sessionID: nil, message: "Could not create a terminal."))
            return
        }

        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let process = Process()
        // Foundation's Process can attach the slave descriptors but does not make them the child's
        // controlling terminal. `script` does the forkpty/setsid/TIOCSCTTY setup, so job control
        // and password prompts behave like a real Terminal window.
        let shell = loginShell()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", shell, "-l"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        // These shells are drawn on a phone by replaying their bytes onto a grid, so a program that
        // repaints cell by cell is every weakness at once, and that is what a full-screen program
        // on the alternate screen does. This is Claude Code's documented way of being told not to:
        environment["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] = "1"
        if shell.hasSuffix("zsh") { Self.installZshFinishHook(into: &environment) }
        process.environment = environment
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave

        let session = Session(id: id, ownerClientID: ownerClientID, name: name, process: process, master: master)
        process.terminationHandler = { [weak self, weak session] process in
            guard let self, let session else { return }
            self.didExit(session, status: process.terminationStatus)
        }
        master.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.received(data, from: session)
        }

        do {
            lock.withLock { sessions[id] = session }
            try process.run()
            try? slave.close()
            if shell.hasSuffix("bash") { Self.installFinishHook(shell: shell, into: master) }
            sink(.created(session.info))
            terminalLog.notice("started terminal \(name, privacy: .public) \(id.uuidString, privacy: .public)")
        } catch {
            Analytics.failed(error, in: .terminal)
            _ = lock.withLock { sessions.removeValue(forKey: id) }
            master.readabilityHandler = nil
            try? master.close()
            try? slave.close()
            sink(.failed(sessionID: id, message: "Could not start the login shell: \(error.localizedDescription)"))
        }
    }

    /// The precmd/preexec-equivalent hook for each shell this app knows how to talk to, one
    /// compact statement so it survives being typed onto a single input line. Both write the same
    /// OSC marker ``TerminalCommandFinishDetector`` looks for, and both check the five-second
    /// threshold themselves, so a trivial command never even produces a marker to detect.
    static let zshFinishHookLine =
        #"zmodload zsh/datetime 2>/dev/null; __mc_preexec(){ __mc_t0=$EPOCHREALTIME; __mc_cmd=$1; }; __mc_precmd(){ local __mc_s=$?; if [[ -n $__mc_t0 ]]; then local __mc_d=$(( (EPOCHREALTIME - __mc_t0) * 1000 )); __mc_d=${__mc_d%.*}; if (( __mc_d >= 5000 )); then printf '\033]9999;%s;%s;%s\007' "$__mc_d" "$__mc_s" "$(printf %s "$__mc_cmd" | base64 | tr -d '\n')"; fi; unset __mc_t0; fi }; precmd_functions+=(__mc_precmd); preexec_functions+=(__mc_preexec)"#

    static let bashFinishHookLine =
        #"export HISTTIMEFORMAT="%s "; set -o history; __mc_last=""; __mc_precmd(){ local __mc_s=$?; local __mc_line; __mc_line=$(history 1); local __mc_ts=$(printf '%s\n' "$__mc_line" | awk '{print $2}'); local __mc_cmd=$(printf '%s\n' "$__mc_line" | awk '{$1="";$2="";print}' | sed 's/^  *//'); local __mc_now=$(date +%s); local __mc_d=$(( (__mc_now - __mc_ts) * 1000 )); if [ "$__mc_line" != "$__mc_last" ] && [ "$__mc_d" -ge 5000 ]; then printf '\033]9999;%s;%s;%s\007' "$__mc_d" "$__mc_s" "$(printf %s "$__mc_cmd" | base64 | tr -d '\n')"; fi; __mc_last="$__mc_line"; }; PROMPT_COMMAND="__mc_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}""#

    /// Points zsh at a directory of wrapper dotfiles that source the real ones and then add the
    /// finish hook, so the hook arrives as configuration and not as typed input.
    static func installZshFinishHook(into environment: inout [String: String]) {
        let wrapper = FileManager.default.temporaryDirectory.appendingPathComponent("peering-zdotdir", isDirectory: true)
        let home = environment["ZDOTDIR"] ?? NSHomeDirectory()
        func forward(_ name: String, extra: String = "") -> String {
            """
            ZDOTDIR=$PEERING_USER_ZDOTDIR
            [[ -f $ZDOTDIR/\(name) ]] && source $ZDOTDIR/\(name)
            \(extra)ZDOTDIR=$PEERING_WRAPPER_ZDOTDIR

            """
        }
        let zshrc = forward(".zshrc", extra: zshFinishHookLine + "\n")
        let zlogin = forward(".zlogin", extra: "")
            + "if [[ -n $PEERING_HAD_ZDOTDIR ]]; then ZDOTDIR=$PEERING_USER_ZDOTDIR; else unset ZDOTDIR; fi\n"
        let files = [
            ".zshenv": forward(".zshenv"),
            ".zprofile": forward(".zprofile"),
            ".zshrc": "[[ $HISTFILE == $PEERING_WRAPPER_ZDOTDIR/* ]] && HISTFILE=$PEERING_USER_ZDOTDIR/${HISTFILE:t}\n" + zshrc,
            ".zlogin": zlogin,
        ]
        do {
            try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
            for (name, text) in files {
                try text.write(to: wrapper.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch {
            terminalLog.error("could not write the zsh wrapper: \(error.localizedDescription, privacy: .public)")
            return
        }
        environment["PEERING_USER_ZDOTDIR"] = home
        environment["PEERING_WRAPPER_ZDOTDIR"] = wrapper.path
        if environment["ZDOTDIR"] != nil { environment["PEERING_HAD_ZDOTDIR"] = "1" }
        environment["ZDOTDIR"] = wrapper.path
    }

    /// Typed into the master like keystrokes, which echoes it once at the top of a new tab. Only bash
    /// still comes this way: it has no equivalent of the `ZDOTDIR` wrapper below for a login shell.
    static func installFinishHook(shell: String, into master: FileHandle) {
        let line = bashFinishHookLine
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? master.write(contentsOf: data)
    }

    func received(_ data: Data, from session: Session) {
        let (attention, finish, question): (
            TerminalAttentionKind?, TerminalCommandFinishDetector.Finish?, String?
        ) = lock.withLock {
            guard sessions[session.id] === session else { return (nil, nil, nil) }
            session.history.append(data)
            // Rebound rather than cut with `removeFirst`, which moves `Data`'s start index instead of
            // compacting and so keeps the whole stream alive behind a buffer that looks its limit.
            if session.history.count > Self.maximumHistoryBytes + Self.historySlackBytes {
                let dropped = session.history.count - Self.maximumHistoryBytes
                session.history = Data(session.history.dropFirst(dropped))
            }
            let kind = session.attentionDetector.receive(data)
            return (kind, session.finishDetector.receive(data), session.attentionDetector.question)
        }

        send(.output(sessionID: session.id, data: data), to: session.ownerClientID)

        if let attention {
            let noun = attention == .password ? "a password" : "confirmation"
            let name = "Terminal \u{201C}\(session.name)\u{201D}"
            // The prompt alone when there is one: "[sudo] password for damian:" says which password
            // and whose. The sentence stays as the fallback for a prompt that cannot be read.
            let message = question ?? "\(name) is waiting for \(noun)."
            send(.attention(sessionID: session.id, kind: attention, message: message), to: session.ownerClientID)
            push(session: session, title: "Terminal needs you", message: message)
        }

        if let finish {
            send(
                .commandFinished(
                    sessionID: session.id,
                    command: finish.command,
                    duration: finish.duration,
                    exitStatus: finish.exitStatus
                ),
                to: session.ownerClientID
            )
            let named = finish.command.map { "\u{201C}\($0)\u{201D}" } ?? "Terminal \u{201C}\(session.name)\u{201D}"
            let message = "\(named) finished\(TerminalCommandFinishDetector.durationSuffix(finish.duration))."
            push(session: session, title: "Terminal finished", message: message)
        }
    }

    func push(session: Session, title: String, message: String) {
        guard let token = PushTokenStore.shared.token(for: session.ownerClientID) else { return }
        onPushNeeded?(token, title, message)
    }

    func didExit(_ session: Session, status: Int32) {
        session.master.readabilityHandler = nil
        lock.withLock {
            guard sessions[session.id] === session else { return }
            session.isRunning = false
        }
        send(.exited(sessionID: session.id, status: status), to: session.ownerClientID)
        terminalLog.notice("terminal \(session.id.uuidString, privacy: .public) exited with \(status)")
    }

    func close(id: UUID, ownerClientID: String) {
        guard let session = lock.withLock({ () -> Session? in
            guard sessions[id]?.ownerClientID == ownerClientID else { return nil }
            return sessions.removeValue(forKey: id)
        }) else { return }
        session.master.readabilityHandler = nil
        if session.isRunning { session.process.terminate() }
        try? session.master.close()
        // A write made through this shell cannot be finished, since every piece after this one is
        // refused for naming a terminal that is gone. Dropped here rather than refused chunk by
        // chunk.
        lock.withLock { writes = writes.filter { $0.key.sessionID != id } }
        send(.closed(sessionID: id), to: ownerClientID)
        terminalLog.notice("closed terminal \(id.uuidString, privacy: .public)")
    }

    func send(_ event: TerminalEvent, to clientID: String) {
        lock.withLock { sinks[clientID] }?(event)
    }
}
