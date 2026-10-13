# Remote desktop competitor features (2026)

Research date: 2026-09-16. Sources are official product pages and documentation only.

## Bottom line

Peering already has a strong, unusual core: account-free SAS pairing, pinned mutual TLS,
end-to-end encrypted relay access, display/app/window capture, Spaces and source switching,
touch controls designed for an iPhone, manual quality controls, reconnection, Picture in Picture,
a Live Activity, a widget, and clear connection diagnostics.

The biggest missing everyday features are:

1. **Clipboard exchange** — preferably explicit “Send clipboard” and “Receive clipboard” actions,
   with automatic sync optional and off by default.
2. **Actual Mac audio** — Peering's current audio session only keeps the iOS app alive; the Mac's
   sound is not transmitted.
3. **File transfer through the iOS Files picker** — explicit transfers with progress, cancel, and
   size limits.
4. **Wake-on-LAN and better sleeping/offline actions** — Peering explains a sleeping display well,
   but cannot wake a Mac that is no longer reachable.
5. **A stronger privacy mode** — the current implementation dims supported physical displays;
   mature products also block local keyboard/mouse input and lock the Mac after disconnect.

These should come before broad team/admin features. Clipboard, sound, and files improve nearly
every personal session; device fleets, audit logs, and remote support codes serve a different
product.

## What competitors establish as table stakes

| Capability | Current competitor pattern | Peering assessment |
| --- | --- | --- |
| iPhone touch/trackpad input and special keys | Screens, Jump, AnyDesk, TeamViewer, Chrome Remote Desktop, and RustDesk all document mobile input modes or gestures. | Strong already. Peering also has Unicode/keycode modes, shortcuts, macros, joystick control, and direct manipulation. |
| Unattended access away from home | Screens Connect, Jump Connect, AnyDesk Unattended Access, TeamViewer Easy Access, Chrome's PIN flow, and RustDesk ID/relay all provide it. | Strong already through paired identities and the encrypted relay, without an account. |
| Clipboard | Screens, Jump Fluid, TeamViewer, AnyDesk, RustDesk, and Apple Screen Sharing expose clipboard sharing. TeamViewer adds one-time send/receive and paste-as-keystrokes. | Missing by design. Best next feature because text frequently begins on the phone. |
| Remote audio | Jump, TeamViewer, AnyDesk, RustDesk, and Apple's High Performance Screen Sharing support host audio. Screens explicitly does not because of its VNC protocol. | Missing. High-value for video, alerts, calls, and media; should have a prominent mute control. |
| File transfer | Screens supports iPhone/Mac drag-and-drop; TeamViewer, AnyDesk, RustDesk, and Apple Screen Sharing offer transfer workflows. | Missing. Use the iOS Files picker/share sheet rather than reproducing a desktop file manager. |
| Multiple monitors | Screens can select one or view all; Jump supports host and virtual displays; AnyDesk and TeamViewer switch monitors; Apple supports side-by-side displays. | Peering can choose a physical display through its source catalogue, but not view several at once or create a phone-sized virtual display. A quick in-session display switcher is the useful first step. |
| Privacy display | Screens Curtain Mode, Jump Privacy Mode, TeamViewer Black Screen, AnyDesk Privacy Mode, and Apple High Performance mode hide the physical screen. Jump and TeamViewer also block local input. | Partial. Peering dims supported displays to 0% brightness and restores them safely, but this is not equivalent to a private virtual display and does not block local input. |
| Quality adaptation and statistics | Screens and Jump advertise adaptive quality; AnyDesk exposes quality control; Jump's current iOS work includes bandwidth/FPS controls and connection stats. | Partial. Peering has Low/Medium/High presets, FPS/video status, path, and latency. An **Auto** mode based on measured throughput/loss would remove manual tuning. |
| Reconnect/background continuity | Screens documents automatic reconnection. Jump exposes configurable background runtime. AnyDesk says iOS sessions close within about five seconds after leaving the app. | A differentiator when reliable: Peering reconnects, has PiP/Live Activity, and attempts to keep sessions alive. However, its silent-audio keepalive is explicitly unsuitable for App Store review and costs battery. |
| Attended support | Screens Assist, Jump screen-sharing links, Chrome one-time codes, TeamViewer, and AnyDesk support temporary help sessions. | Missing and optional. Add only if Peering wants to become a support tool rather than a personal remote-control app. |
| Wake and power actions | TeamViewer documents Wake-on-LAN; Apple Remote Desktop can wake, restart, sleep, and shut down managed Macs. | Peering can lock the Mac and prevent sleep, but no Wake-on-LAN path was found. |
| Screenshot/session recording | Screens can grab/share screenshots; AnyDesk and TeamViewer expose screenshots or session recording. | Missing, but lower priority than clipboard/audio/files. iOS screen recording already covers some of this need. |

## Competitor notes

### Screens 5

Screens is the closest Apple-first comparison. It offers remote access from iPhone, iPad, Mac,
and Vision Pro, touch/trackpad modes, hardware keyboard and pointing-device support, display
selection, clipboard, iPhone-to-Mac file transfers, Curtain Mode, observe-only mode, adaptive
quality, screenshots, and temporary assistance. It can connect away from home using Screens
Connect and integrates with Tailscale and NordVPN. It does **not** transmit computer sound.

Useful references:

- [Screens product and feature overview](https://www.edovia.com/en/screens/)
- [Screens feature index](https://help.edovia.com/en/screens-5/features/)
- [Curtain Mode](https://help.edovia.com/en/screens-5/features/curtain-mode)
- [Observe and Control modes](https://help.edovia.com/en/screens-5/features/observe-and-control-modes)
- [Screens Connect remote access](https://help.edovia.com/en/screens-5/connecting-anywhere/screens-connect-in-screens)

### Jump Desktop

Jump's Fluid protocol combines 60 fps desktop sharing, host audio, end-to-end encryption,
adaptive quality, clipboard, multi-monitor selection, local-account authentication, and
unattended access. On iPhone it has a mature gesture vocabulary, auxiliary keypads, physical
mouse support, and Privacy Mode. Its newer display system adds phone-sized virtual displays,
Retina modes, custom resolutions, and saved layouts; some multi-display features require an
Enterprise plan.

Useful references:

- [Fluid Remote Desktop features](https://support.jumpdesktop.com/hc/en-us/articles/216423983-General-Fluid-Remote-Desktop)
- [iPhone/iPad gestures](https://support.jumpdesktop.com/hc/en-us/articles/216423503-Getting-Started-Jump-Desktop-Controls-and-Gesture-Reference)
- [Mac audio streaming](https://support.jumpdesktop.com/hc/en-us/articles/360035566472-Mac-How-to-stream-audio)
- [Unattended access](https://support.jumpdesktop.com/hc/en-us/articles/360025731531-Setup-Unattended-Remote-Access)
- [Privacy Mode](https://support.jumpdesktop.com/hc/en-us/articles/18250305826573-Privacy-Mode-for-Fluid)
- [Displays and virtual displays](https://support.jumpdesktop.com/hc/en-us/articles/45768818796813-General-Using-the-Display-menu-and-virtual-displays-in-Fluid-sessions)

### TeamViewer Remote

TeamViewer's breadth is the benchmark for a support/business product: mobile control,
unattended Easy Access, Wake-on-LAN, remote audio, bidirectional and one-shot clipboard actions,
encrypted file transfer, multi-monitor/4K, black screen plus blocked local input, chat/VoIP,
session recording, device lists, and remote printing. Current security documentation describes
mutually authenticated TLS 1.3 with forward secrecy and AES-256-GCM end-to-end encryption.
Personal use has a free tier; business use is paid.

Useful references:

- [TeamViewer Remote features](https://www.teamviewer.com/en/products/remote/features/)
- [iOS interaction methods](https://www.teamviewer.com/en/global/support/knowledge-base/teamviewer-classic/mobile/ios/interaction-methods-on-ios/)
- [Clipboard controls](https://www.teamviewer.com/en-us/global/support/knowledge-base/teamviewer-remote/remote-control/control-clipboard-sync-during-remote-support-sessions/)
- [Easy Access](https://www.teamviewer.com/en/global/support/knowledge-base/teamviewer-classic/remote-control/connection-methods/remote-control-via-easy-access/)
- [Security statement](https://www.teamviewer.com/pl/global/support/knowledge-base/teamviewer-remote/security/security-statement/)

### AnyDesk

AnyDesk's iOS client exposes touch/touchpad input, special keys, quality controls, clipboard,
remote-user input blocking, privacy mode, cursor options, monitor switching, screenshots, chat,
recording, and file browsing/transfers. macOS host audio is supported on macOS 13 and newer.
Unattended access can use a password, automatic login, and 2FA. Its iOS documentation warns
that backgrounding the app ends a session within roughly five seconds. Current platform docs
also say outgoing sessions from iOS require a paid license, which leaves room for a simpler
personal product.

Useful references:

- [AnyDesk for iOS/iPadOS/tvOS](https://support.anydesk.com/anydesk-for-ios-ipados-tvos)
- [File manager and file transfer](https://support.anydesk.com/file-manager-and-file-transfer)
- [AnyDesk for macOS](https://support.anydesk.com/anydesk-for-macos)
- [Unattended Access](https://anydesk.com/en/features/unattended-access)
- [Multiple displays](https://support.anydesk.com/how-do-i-work-with-multiple-displays)

### Chrome Remote Desktop

Chrome Remote Desktop is the simple/free baseline: a Google-account computer list, PIN-based
unattended access, temporary support codes, encrypted sessions, and an iOS virtual trackpad with
click, right-click, scrolling, zoom, drag, and middle-click gestures. Direct-touch mode is not
available for Mac/Linux. Google's iOS documentation does not describe remote audio, clipboard,
file transfer, multi-monitor selection, privacy screen, or recording, so those should be treated
as undocumented rather than claimed categorically absent.

- [Access another computer from iPhone or iPad](https://support.google.com/chrome/answer/1649523?co=GENIE.Platform%3DiOS&hl=en-KG)
- [Administrative controls and Mac curtain-mode limitation](https://support.google.com/chrome/a/answer/2799701?hl=en)

### RustDesk

RustDesk differentiates through open-source clients and a free self-hosted signaling/relay
server. It supports Windows, macOS, Linux, iOS, Android, and web; documents P2P end-to-end
encryption, hardware H.264/H.265 and other codecs, clipboard, files, host audio, touch/mouse
modes, and detailed per-permission controls. Its paid self-hosted server adds a web console,
OIDC/LDAP, 2FA, device management, access control, and audit logs.

- [RustDesk overview and features](https://rustdesk.com/docs/en/)
- [RustDesk client platforms and settings](https://rustdesk.com/docs/en/client/)
- [Clipboard, file, audio, and touch-mode settings](https://rustdesk.com/docs/en/self-host/client-configuration/advanced-settings/)
- [OSS versus Pro self-hosting](https://rustdesk.com/docs/en/self-host/)

### Apple Screen Sharing and Remote Management

Apple does not offer a first-party iPhone-to-Mac viewer, so these are technical benchmarks rather
than direct mobile competitors. Mac-to-Mac Screen Sharing supports full control, clipboard, and
drag-and-drop files. High Performance mode adds stereo audio, low latency, HDR, 4:4:4 color,
30/60 fps, one or two virtual displays, and hardware-display blanking. Apple Remote Desktop adds
multi-Mac administration, multi-display layouts, curtain/lock screen, file/package distribution,
screenshots, scripts, reports, and power actions. Apple Remote Desktop is Mac-only and a paid
one-time purchase.

- [Mac Screen Sharing](https://support.apple.com/en-ca/guide/mac-help/mh14066/mac)
- [Screen Sharing clipboard and file transfer](https://support.apple.com/en-ie/guide/mac-help/mchl89584923/mac)
- [High Performance Screen Sharing](https://support.apple.com/en-lamr/guide/mac-help/mchl1883115d/mac)
- [Apple Remote Desktop capabilities](https://support.apple.com/en-gb/guide/remote-desktop/apd2450a787/mac)

## Recommended product order

### 1. Finish reliability and distribution constraints

Before adding protocol surface, keep reconnect, sleep/wake recovery, permission guidance, and
long sessions boringly reliable. If App Store distribution matters, replace or remove the silent
audio background keepalive; the source itself correctly notes that Apple rejects this pattern.

### 2. Add privacy-first clipboard exchange

Start with explicit **Send Phone Clipboard** and **Receive Mac Clipboard** buttons, text and URLs
only, a visible preview, size cap, and no background reads. This preserves Peering's “nothing is
sent unless asked” character. Optional automatic sync can follow. TeamViewer's one-time actions
are a better model for Peering than invisible always-on synchronization.

### 3. Add Mac sound

Transmit stereo system audio over its own droppable channel, with mute on by default until the
user enables it. Keep microphone forwarding out of the first version; it is a different privacy
promise and a much harder feedback/echo problem.

### 4. Add deliberate file transfer

Use the iOS Files picker and share sheet, make direction obvious, show progress and cancellation,
and require an explicit action for every transfer. Do not silently extend clipboard sync to files.

### 5. Improve sleeping and privacy behavior

Add Wake-on-LAN when a paired Mac is known but offline. Extend Privacy Mode, where macOS permits,
to block local input and optionally lock after disconnect. Be precise in the UI about whether the
physical display is truly blanked or merely dimmed.

### 6. Polish displays and quality

Put fast display switching directly in the session chrome and remember the chosen display per
Mac. Then consider an iPhone-sized virtual display and an **Auto** quality setting. Viewing all
physical monitors simultaneously is less useful on an iPhone than switching instantly between
them.

### 7. Choose whether remote support is in scope

If yes, add expiring guest codes/links, explicit local approval, observe-only mode, and a clear
“someone is connected” host indicator. If no, keep the pairing model focused and avoid the admin,
chat, audit, and fleet-management surface that makes TeamViewer/AnyDesk complex.

## Peering's strongest differentiation

Do not bury these under a generic feature race:

- no account, no analytics, and no third-party SDKs;
- SAS comparison rather than a reusable pairing PIN;
- mutual TLS and pinned device identities, including over the relay;
- iPhone-first controls instead of a scaled-down desktop toolbar;
- whole-display, single-app, and single-window capture, plus Spaces previews;
- PiP, Live Activity, widget quick connect, and explicit LAN/direct/relay diagnostics.

The product opportunity is “the private, native way to drive your own Mac from your iPhone,” not
“a smaller TeamViewer.”
