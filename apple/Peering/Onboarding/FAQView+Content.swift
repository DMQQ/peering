import SwiftUI

extension FAQView {
    static let sections: [Section] = [
        Section(
            title: String(localized: "Getting started"),
            items: [
                QA(
                    question: String(localized: "Do I need an account?"),
                    answer: String(localized: "No. Each device creates its own identity and keeps the key in that device's Keychain. There is no sign-up, no email, and nothing about you stored on a server.")
                ),
                QA(
                    question: String(localized: "How do I pair a Mac?"),
                    answer: String(localized: "The two devices have to be able to reach each other once, and somebody has to be at the Mac. On the same network, choose the Mac from Nearby. If it is somewhere else, open Devices in Peering on the Mac, copy its device ID, and use Pair from Another Network on the iPhone. Either way the Mac shows six digits: enter them on the iPhone and continue only if they match. You pair once; after that the devices recognise each other and reconnect on their own.")
                ),
                QA(
                    question: String(localized: "What does the Mac need?"),
                    answer: String(localized: "The Peering app for macOS, running, with two permissions allowed: Screen Recording, which is what lets it capture the screen, and Accessibility, which is what lets it move the pointer and type. Both live in System Settings → Privacy & Security, and the Mac app shows their state with a button to open the right pane.")
                ),
                QA(
                    question: String(localized: "Can I connect away from home?"),
                    answer: String(localized: "Yes, and it tries two ways in order. First the two devices look for a path straight between themselves; if the networks will not allow one, Peering's relay carries the session instead. The session screen shows which is in use as LAN, RELAY, or DIRECT·P2P. You can turn the relay off entirely under Settings → Remote access, which leaves connections on your own network only.")
                ),
                QA(
                    question: String(localized: "Does my Mac have to be awake?"),
                    answer: String(localized: "It has to be on to hold a session. A Mac you have paired with can be woken from the ⋯ menu on its row in the Connect tab, which offers Wake Mac on LAN. That packet goes out on the local network, so it only reaches a Mac on the same network as your phone, and it needs an address for the Mac, which Peering learns the first time you connect to it. The item is in the menu either way: when it cannot be used it is greyed out and says which of the two is missing, and it is greyed out while the Mac is already awake as well. A sleeping Mac off your network cannot be woken from here.")
                ),
                QA(
                    question: String(localized: "How many Macs can I use?"),
                    answer: String(localized: "As many as you pair. They all appear in the Connect tab, and you can have several open at once, one tab per Mac. Tapping a tab switches to that Mac without disconnecting the one you left, and its shells keep running.")
                ),
                QA(
                    question: String(localized: "Can two phones use the same Mac?"),
                    answer: String(localized: "One phone drives a Mac at a time. While one is connected, a second is turned away and offered Take over. A phone that has gone silent is replaced on its own after about 20 seconds, or after about 3 minutes if it was in the background. Take over works only for a phone already paired with that Mac, and it disconnects the other one.")
                ),
            ]
        ),

        Section(
            title: String(localized: "Why it works this way"),
            items: [
                QA(
                    question: String(localized: "Why does my Mac need an app?"),
                    answer: String(localized: "Only software running on the Mac can capture its screen and click or type in other apps, and macOS allows that only after you grant Screen Recording and Accessibility. The iPhone cannot do it from outside. So the Mac app does the sharing, and this app shows the picture and sends your input back. The Mac app is a download from getpeering.app rather than a Mac App Store app, because a sandboxed app cannot send input to other apps.")
                ),
                QA(
                    question: String(localized: "What is it actually doing?"),
                    answer: String(localized: "The Mac app captures a display, an app or a window, compresses it as video and sends it to the phone, with the Mac's sound if you leave it on. Your taps and keys go the other way, and the Mac app turns them into real pointer and keyboard events. Away from your network the session goes through Peering's relay, which copies encrypted bytes it holds no key for.")
                ),
                QA(
                    question: String(localized: "What are the limits?"),
                    answer: String(localized: "The Mac has to be on, with the Mac app running and both permissions allowed. Away from your own network the relay is free for 30 minutes a day. A Mac that is asleep and off your network cannot be woken, and iOS suspends this app in the background unless Picture in Picture or a Live Activity is running. Known gaps, at the bottom, lists what is not built yet.")
                ),
                QA(
                    question: String(localized: "Can I read the code?"),
                    answer: String(localized: "Yes. The iPhone app, the Mac app, the relay and the wire protocol are in one public repository, github.com/DMQQ/peering. Read it to check anything described here, including exactly what is sent.")
                ),
            ]
        ),

        Section(
            title: String(localized: "Privacy"),
            items: [
                QA(
                    question: String(localized: "Can the relay see my screen or controls?"),
                    answer: String(localized: "No. It forwards an encrypted connection it holds no key for. The video, the audio, clipboard text, keystrokes and pointer input are all inside that connection, and the relay can read none of them.")
                ),
                QA(
                    question: String(localized: "What does the relay know?"),
                    answer: String(localized: "The Mac's device ID and name, your iPhone's device ID, the protocol version, which plan the app says you are on, and how much you have used it. A paid connection also sends its relay access key. It does not see inside the session, and it does not keep a record of what was on your screen.")
                ),
                QA(
                    question: String(localized: "Does the video go through your servers?"),
                    answer: String(localized: "Only when it has to. When the two devices can reach each other directly, the picture takes that path and only the control connection stays on the relay. When they cannot, which is common on restrictive networks, the relay carries the picture too. This is not a setting; the app tries the direct path and falls back on its own.")
                ),
                QA(
                    question: String(localized: "Can I stop someone at the Mac from watching?"),
                    answer: String(localized: "Yes. Turn on Darken the Mac's displays during a session and the Mac's own screens go dark while capture keeps running, so you can work without the room reading over your shoulder. They come back when you turn it off or end the session.")
                ),
                QA(
                    question: String(localized: "Can I lock the app, or one server?"),
                    answer: String(localized: "Both. A lock for the whole app is under Settings, and asks each time the app comes back. Your device passcode is accepted as well as your face, so a phone that stops recognising you cannot lock you out of the app. Each saved SSH server can separately require the same, or a six-digit passcode of your own before it will open.")
                ),
                QA(
                    question: String(localized: "What does Peering collect?"),
                    answer: String(localized: "Anonymous usage counts and error codes, sent to PostHog: which screens are opened, whether a connection worked and at which stage it failed, and the kind of network. Never a Mac's name or address, a file name, a command, or anything typed or shown. Events belong to the device, not to a person, and there is no advertising. Turn it off with Share anonymous usage statistics in Settings; the Mac app has the same switch. The diagnostics you can copy from Settings go nowhere unless you send them yourself.")
                ),
            ]
        ),

        Section(
            title: String(localized: "What moves between devices"),
            items: [
                QA(
                    question: String(localized: "Is Mac audio sent?"),
                    answer: String(localized: "Yes, and you hear it. Whatever the Mac plays comes out of the phone, from the music you left running to the alert it makes in answer to a key you sent it. Sound from the Mac is a switch in the session panel, under Stream, on by default. Turning it off is a tap rather than a teardown: the audio keeps arriving and is dropped here, so turning it back on is instant.")
                ),
                QA(
                    question: String(localized: "How does clipboard sharing work?"),
                    answer: String(localized: "Text moves only when you ask it to: pull the Mac's clipboard, push this phone's, or pick something you pulled earlier. The phone keeps your 25 most recent pulls so you can pick one again. All of it is free. Nothing is copied in the background.")
                ),
                QA(
                    question: String(localized: "Can I transfer files?"),
                    answer: String(localized: "Yes, from the file browser inside a terminal. You can read a file, download it to the phone, edit a text file and save it back, make a new file or folder, rename or delete what is listed, and send a file from the phone into the folder you are looking at. Deleting moves the file to the Bin on your own Mac; on an SSH server it is gone, and the confirmation says so. What a file is gets decided by the file itself rather than its name, so a picture opens as a picture and anything that is neither text nor a picture is refused rather than shown as rubbish. The limits are worth knowing: text files are read up to 128 KB, and a longer one can be read but not edited or downloaded, because saving would replace the whole file with only the part you were shown. Sending a file the other way is capped at 2 GB, which is a limit on the waiting rather than on the phone's memory.")
                ),
                QA(
                    question: String(localized: "Can I open a terminal?"),
                    answer: String(localized: "Yes, two kinds. One is a shell on the Mac itself, opened inside the session, with tabs you can rename and a key row for the control keys a phone keyboard cannot send. The other is a saved SSH server, which connects straight from the phone and does not involve the Mac at all. Both file browsers can browse, preview, download, edit, upload, and make, rename or delete what they list.")
                ),
                QA(
                    question: String(localized: "Can I use coding agents?"),
                    answer: String(localized: "Yes. Peering can run Claude Code, Codex and OpenCode on the Mac. You chat with them from the phone, review what they changed, commit and push, and answer their permission requests from the Lock Screen.")
                ),
                QA(
                    question: String(localized: "Can I reach my server, or only my Mac?"),
                    answer: String(localized: "Any SSH server you add under Servers. Sign in with a password, kept in the Keychain if you ask for that, or with a key: make one here and copy the public half into the server's authorized_keys, or paste a private key you already have, passphrase and all. What this app can sign with is ed25519 and RSA. The first time you connect, the server's key fingerprint is shown for you to confirm. That server's files are reachable through the same browser as the Mac's.")
                ),
                QA(
                    question: String(localized: "What is port forwarding for?"),
                    answer: String(localized: "Reaching something that only the server can see: a database behind a firewall, a service listening on the Mac's own network, a web page on a machine with no route to the internet. A forward opens a port on this phone and lets the far end make the connection, so an app here points at localhost and gets through. The listener is on this phone's loopback only, so nothing on the wifi you are sitting on can reach it.")
                ),
                QA(
                    question: String(localized: "What are macros and quick commands?"),
                    answer: String(localized: "Saved commands you fire with a tap rather than typing them on glass. Quick commands are the chips above the terminal keyboard, and the same list is waiting in every shell; macros are longer sequences you record once. Using them and making them are both free.")
                ),
                QA(
                    question: String(localized: "Can I switch between the Mac's desktops?"),
                    answer: String(localized: "Yes. The Apps panel draws every Space each screen has as a picture rather than a list of names, and tapping one brings it forward and moves the picture to that screen, which is the only practical way to move between them from a phone.")
                ),
            ]
        ),

        Section(
            title: String(localized: "Plans"),
            items: [
                QA(
                    question: String(localized: "What is free?"),
                    answer: String(localized: "Everything in the app. Connecting over your own network has no limit and no time counted. The relay is the part that reaches a Mac on another network, and free includes 30 minutes of it each day. A paid plan adds only one thing: unlimited relay time.")
                ),
                QA(
                    question: String(localized: "What happens when my relay time runs out?"),
                    answer: String(localized: "The relay stops carrying sessions until the allowance resets, which happens once a day at midnight UTC, and the Sessions tab shows the meter counting down. Connections on your own network keep working the whole time. Any paid plan removes the limit entirely.")
                ),
                QA(
                    question: String(localized: "Why does the app ask me to subscribe?"),
                    answer: String(localized: "It asks after your first session, and again if your relay allowance is nearly gone. Both are a single prompt with a way to dismiss it; nothing is charged without you confirming it through the App Store.")
                ),
            ]
        ),

        Section(
            title: String(localized: "Security and troubleshooting"),
            items: [
                QA(
                    question: String(localized: "How are paired devices verified?"),
                    answer: String(localized: "Each device creates its own key and keeps it in the Keychain. When you confirm the six-digit code, both devices record the other's public key and refuse to connect to anything else claiming that identity. The relay cannot substitute itself for either end.")
                ),
                QA(
                    question: String(localized: "Why is the Mac screen black?"),
                    answer: String(localized: "Almost always Screen Recording. Check System Settings → Privacy & Security → Screen Recording on the Mac, then fully quit Peering on the Mac and open it again. The permission is only picked up at launch.")
                ),
                QA(
                    question: String(localized: "The picture looks soft. Can I change it?"),
                    answer: String(localized: "Yes. The speedometer chip on the session screen sets Auto, Low, Medium or High. Auto follows what the connection can carry, stepping down when latency rises and back up when it settles, so a weak link goes soft rather than stalling.")
                ),
                QA(
                    question: String(localized: "Will a session stay connected in the background?"),
                    answer: String(localized: "Picture in Picture keeps the live view over other apps, and the Live Activity keeps the session's state on the Lock Screen. Without those, iOS suspends the app after a short grace period and the session drops. Peering then retries a few times with a growing gap, and picks the session back up if you return.")
                ),
                QA(
                    question: String(localized: "What happens if my phone changes network?"),
                    answer: String(localized: "The session cannot survive it: the address the Mac was sending to stops existing, and the connection neither fails nor closes, it simply goes quiet. Peering counts that quiet, and ends the session after ten seconds of it without an answer, so you are told and can connect again instead of watching a last frame that never moves. Join the new network, tap the Mac, and you are back.")
                ),
                QA(
                    question: String(localized: "Why can't I edit this file?"),
                    answer: String(localized: "Three reasons, and the panel says which. The file was longer than the read limit, so only its beginning is on screen and saving would throw the rest away. Or it is not text in UTF-8, which this editor cannot represent. Or the shell it was opened from has ended, in which case there is nothing left to save through.")
                ),
            ]
        ),

        Section(
            title: String(localized: "Known gaps"),
            items: [
                QA(
                    question: String(localized: "What can't Peering do yet?"),
                    answer: String(localized: "A list rather than a promise. There is no dictation button. A port forward listens on this phone only: there is no way to open one on the server's side, which is what ssh -R is for. A Mac asleep and off your network cannot be woken. A Mac with its lid shut and no screen attached has nothing to show unless this phone has made a virtual display for it.")
                ),
                QA(
                    question: String(localized: "Is any of that coming?"),
                    answer: String(localized: "Some of it. Nothing on that list is a design decision we are defending; each is simply not built. The FAQ will say so when it changes, because a list like this is only worth reading if it is kept.")
                ),
            ]
        ),
    ]
}
