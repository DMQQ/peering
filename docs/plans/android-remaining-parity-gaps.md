# Android remaining parity gaps

Scope: onboarding, pairing, FAQ, Sessions, Settings below Session controls, paywall, the two Connect sheets and the forget and rename dialogs. Compared by reading the Swift view source and the Android Compose source. Nothing was run on a device or emulator, so every "Android status" is from reading code and from the JVM tests and `assembleDebug`, not from looking at the screen.

Status words: **matched** (same layout, order, copy, values), **fixed** (differed, changed in this pass), **differs** (still different, reason given), **skipped** (iOS only or not built, reason given).

## Onboarding

| Screen | iPhone element and value (file) | Android status |
|---|---|---|
| Landing | Backdrop with glow, phone pair rotated -6 and 4 degrees, overlap 0.3, drop 0.07, bleed 1.1, three chips at y 0.06, 0.5, 0.76 (`WelcomeHero.swift`) | matched (`WelcomeHero.kt` uses the same constants) |
| Landing | Title "Your Mac. Wherever you are." serif 40, tracking -1.4, solid ink (`WelcomeLanding.swift`) | fixed: Android painted it with the sheen brush, now solid ink. Copy says "computer" |
| Landing | Body `.body` secondary; primary button below, Skip top trailing | matched |
| Primary button | 54 tall capsule, headline bold, ink fill, onInk label (`WelcomeView.swift`, `WelcomePrimaryButton`) | fixed: was Material's default button; new `WelcomePrimaryButton` in `ui/kit/WelcomeButton.kt`, used on landing, tour and paywall |
| Tour pages 1 to 7 | Same titles, bodies, chip symbols and y fractions (`OnboardingView.swift` `pages`) | matched, except page 5 body: iPhone says "Live Activities keep the session close", Android says "a notification" (no Live Activity on Android) |
| Tour | No back arrow; swipe, then Skip jumps to plans (`OnboardingView.swift`) | fixed: Android had an extra back arrow top left, removed; system back and swipe remain |
| Tour | Page dots 6 pt, active 24 pt capsule, spring | matched (`PageDots`, tween 200 ms instead of a spring) |
| Plans page | Rows: Free, "Pro" (note "Unlimited time away, the sharpest relay picture", price per month), "Lifetime" (note "Everything in Pro, paid once", badge "Best value", one time) (`PlanOfferCards.swift`) | fixed: titles and notes were "Monthly"/"Yearly"/"Lifetime" with different notes. Android also sells a yearly plan that the iPhone does not; it is kept and titled "Pro, yearly" with the Pro note |
| Plan row | Check-circle 20 pt (accent when chosen, ink 30% when not), title subheadline semibold, note caption, padding 16 x 14, radius 24, ring 1.5 accent, price display 22 tracking -0.6, caption2 caption | fixed (`PlanCard.kt`). Radius is 28 not 24: the repo's shape scan test forbids literal radii and the theme has no 24 |
| Plans page | Loading and unavailable are one spinner with a caption (`OnboardingView+Plans.swift`) | fixed: Android showed a Free card plus tappable text; now spinner and caption (tap retries) |
| Plans button | "Continue with Pro · $/mo", "Get Lifetime · $", "Contacting the App Store…", "Start using Peering" | fixed: "Continue with Pro · %s/mo" or "/yr", "Get Lifetime · %s", "Contacting the store…" |
| Plans links | Restore purchases, Privacy Policy, Terms of Use, caption2 | matched |
| Plans hero, chips | `PlansHero.swift` mask 0.4 to 1, chips y 0.2, 0.42, 0.7 | matched |
| Pro already | Seal icon, "You are on Pro" | matched |

## First connection guide (`FirstConnectionScreen.swift`)

| Element | iPhone value | Android status |
|---|---|---|
| Title, subtitle, five steps with ticks 700 ms then 450 ms | serif 32, steps Install, Open, Choose, Enter the code, Approve | matched |
| Install link | Row with the address, arrow, and a separate 48 pt copy button that shows a check for 2 s | fixed: copy button was missing |
| Alternatives under the list | "Scan QR code" and "Enter address" | fixed: Android offered "Enter device ID" and "Enter address". Now Scan QR code and Enter address; Enter device ID returns only when the camera is unavailable |
| Steps 4 and 5 | Code entry and approval happen inside this same screen | differs: Android goes to the separate pairing screen after a choice, which then shows four steps. Moving the code step in needs the pairing presenter hosted here; not done |
| Local network notice | `LocalNetworkNotice` when the system refuses | differs: no equivalent permission on Android (Connect shows the no-Wi-Fi notice) |
| Footer | "I'll do this later", becomes "Cancel pairing" | matched for idle; cancel lives on the pairing screen |

## Pairing screens (`PairingPrompt.swift`, `PairingCodeEntry.swift`, `PairingCodeCells.swift`, `PairingApproveDetail.swift`)

| Element | iPhone value | Android status |
|---|---|---|
| Title | "Pair with “{host}”" serif 30, tracking -1 | fixed: was generic "Pair with your computer" in headlineMedium 28. Now named when the name is known from discovery (not for pairing by address or by ID) and 30 / -1 |
| Step 1 detail | "Connected to “{host}”. It is showing six digits." | fixed (named variant) |
| Code detail | "Peering on “{host}” is showing six digits." | fixed (named variant) |
| Approve detail | "Click Approve on “{host}”. It is asking whether you entered the code." | fixed (named variant) |
| Code cells | Six cells, height 60, mono 28 semibold, 8 gap, accent ring 1.5 on the current one, danger ring and shake when wrong, "Scan QR code instead" | matched |
| Wrong code | Shake only | differs: Android adds a "tries left" line, because Android limits attempts visibly |
| Scanned code | Approve step titled "Securing the pairing", detail "Finishing a secure pairing with…" | differs: the presenter does not record whether the code was typed or scanned |
| Cancel | "Cancel pairing" footer | matched |
| Failure state | iPhone shows the failure on the host list | differs: Android shows a dedicated failed state with a Back button; kept, it carries the details text |

## Connect sheets and dialogs

| Element | iPhone value | Android status |
|---|---|---|
| Connect by Address | Title in the display face (`TabScreenHeader`, 34), address field and 88 pt port field, 44 pt Connect button with arrow | fixed: title was 28, button had no arrow and was a stock height. Title 34 / -1.2, 44 pt ink button with arrow |
| Pair from Another Network | Same title, Device ID card, paste row, scan row, footer, error line, Pair button with arrow | fixed: title and button as above |
| Pair sheet, relay off | "Remote access is turned off in Settings. Turn it on to reach a Mac from another network." and Pair disabled | differs: the entry state does not know the relay switch; not added |
| Forget alert | "This Mac will be removed from Trusted Macs. You can re-pair it at any time." | fixed copy: "...removed from Trusted computers. You can re-pair it at any time." |
| Rename alert | Title "Rename this Mac", field "Name", message "The new name is only used on this device. The Mac keeps its own name.", Save and Cancel | matched in copy. Material dialog instead of a system alert (system behaviour) |

## FAQ (`FAQView.swift`)

| Element | iPhone value | Android status |
|---|---|---|
| Header, six section cards, hairline white 7% dividers, chevron rotates 90 degrees | subheadline semibold question, `.callout` answer | answer text fixed to 16 / 21 (was 15); rest matched |
| Questions | 33 | differs: 27 on Android. Missing on purpose: Mac audio, servers and port forwarding, "lock one server", "reach my server", "more than one Mac at once", "switch between desktops", "background", "why can't I edit this file". Each needs the Android behaviour confirmed before an answer is written |

## Sessions tab (`HostPickerView+ActivityTab.swift`, `SessionHistory.swift`)

| Element | iPhone value | Android status |
|---|---|---|
| Header "Sessions", "Recent sessions and relay use." | matched | matched |
| Relay card | Section label, "Free relay time" with left time, 6 pt bar (accent, caution when low), bandwidth line and "last 24 hours", note, upgrade button when low | the "last 24 hours" label was "today": fixed. Bandwidth received is not shown: differs, the Android session record keeps no byte count |
| Recent connections card | Summary of Sessions, Connected, Video; then rows with tile, name, detail, relative time, chevron | summary third column is Relay time, not Video: differs, same missing byte count. Rows matched |
| Detail screen | Connection card (Mac, Path, Started, Duration, Connected when interrupted, Video received), Session log with entries, copy button | differs: no Video received row, no log entries (none are recorded), no copy button, no Connected row. Back is a header row, not a navigation bar |
| SSH shell rows | Servers in the list | skipped: SSH is out of scope on Android |

## Settings below Session controls (`SettingsTab*.swift`)

| Card | iPhone | Android status |
|---|---|---|
| Stream quality | Menu row "Quality", menu titles with bitrate, footer | matched |
| Remote access | "Allow relay connections", Privacy mode only in session, "Upgrade to Pro" | matched (privacy mode is a session setting on Android) |
| Invite a friend | Code, Share, Enter a friend's code, footer | skipped: the relay messages exist in `core/wire` but no client, store or UI is built. A real gap, listed for a later pass |
| Security and privacy | Require biometrics, Share anonymous usage statistics | the analytics row is skipped: Android collects no statistics and says so in the footer |
| Picture in Picture, Home Screen widget, Live Activity | iOS cards | skipped: iOS only |
| Notifications | Permission state and push registration | skipped: no Android equivalent built |
| Trusted Macs | Rows with Forget | matched, plus a confirmation Android adds |
| Device identity | ID, key, count | matched |
| Developer | Plan override, DEBUG only | skipped: not in release builds on the iPhone either |
| More | Peering for Mac, Show introduction again, Show tips again, Report an issue, Copy diagnostics | fixed: Copy diagnostics added (check icon and "Copied" for 2 s). "Show tips again" skipped, Android has no tip tours |
| Legal | Privacy policy and Terms of use, both external links with an arrow, icons hand and document | fixed: they opened in-app text pages; now they open the web pages like the iPhone. The "Open source notices" page stays in the app (Android licence requirement, not on the iPhone). "Terms of service" renamed "Terms of use" |

## Paywall (`PaywallView*.swift`, `AllowanceSpentView.swift`)

| Element | iPhone value | Android status |
|---|---|---|
| Layout | Scroll of header, plans, footer; bottom bar with the buy button and the three links on a material | fixed: Android was a Material column with outlined panels. Rebuilt as scroll plus pinned bar |
| Header | Pears 56, title serif 28 tracking -1, detail subheadline, running-low bar 6 pt caution | fixed (`PaywallHeader.kt`, bar fraction tested in `RunningLowMeterTest`) |
| Titles | "Keep going from anywhere" for spent, "Connect from anywhere", "Running low on relay time" | fixed: spent title was "Your free relay time is used up" |
| Details | Upgrade, spent and low sentences; "Pro removes the limit." | fixed |
| Plan rows | Same cards as the tour, without Free | fixed |
| Unavailable | "Prices could not be loaded", caption, bordered small "Try again" | fixed layout; Android's body names the Play reason |
| Awaiting approval | "Waiting for approval. This plan starts as soon as whoever has to approve it does, and nothing is charged until then." | fixed |
| Footer | Renewal note caption2 tertiary, centred | fixed |
| Thank-you screen | Full screen with feature list after a purchase | differs: Android shows "Start using Peering" in the bar and the already-unlimited line; the feature list is not built |
| Allowance spent | Clock icon 46, serif 28 title, detail, "See the plans", "Not now" | fixed: Android had Material buttons and an extra "left today" line |
| "Not now" on the paywall | iPhone dismisses by swiping the sheet down | Android keeps an explicit "Not now" under the links (system behaviour: no sheet drag here) |

## Skipped by the plan

SSH servers and the Servers tab, Live Activity, Lock Screen and Home Screen widgets, Picture in Picture settings, push notification registration, Wake on LAN, analytics, the Mac resume card.

## Not done in this pass, in order of visibility

1. Invite a friend card (client for `referralStatus`, store, UI).
2. Code entry inside the first-connection screen.
3. Session record byte count, then the Video summary figure, Video received row and the relay bandwidth line.
4. Session log in the detail screen and its copy button.
5. FAQ entries for features Android has since gained.
6. The relay-off notice on the Pair from Another Network sheet.
