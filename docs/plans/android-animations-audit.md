# Android animations audit

Every animation in `android/app/src/main`, as found, with a verdict and what was done. The motion system that replaced
the ad hoc numbers is in `ui/kit/Motion.kt`.

## The motion system

| Name | Value | Used for |
| --- | --- | --- |
| `Motion.fast()` | 120 ms, FastOutSlowIn | press feedback, crossfades, small swaps |
| `Motion.standard()` | 220 ms, FastOutSlowIn | anything that enters, moves or recolours; list placement |
| `Motion.emphasized()` | 320 ms, emphasized decelerate | large surfaces arriving |
| `Motion.exit()` | 90 ms, FastOutLinearIn | anything leaving (always shorter than its entrance) |
| `Motion.spring()` | damping ratio 1.0 (no bounce), medium stiffness | resizes, expansion, pill, dots, pager settle |
| Shared axis X | 30 dp slide over 300 ms, old page out in 90 ms, new page in over 210 ms after that, FastOutSlowIn | every pushed page that stays in Compose |

Rules applied: no scale-in; entrances fade and rise 8 dp at most; exits are faster than entrances; content swaps in a
screen crossfade only; press feedback is scale 0.97 and alpha 0.85 (`Modifier.pressFeedback`, `Modifier.pressable`);
lists use `listItemMotion()` and nothing animates on a screen's first composition; loading states appear after 150 ms
(`Modifier.loadingFade`); nothing runs forever.

## Audit

| Site | What it did | Duration and easing (before) | Verdict | Now |
| --- | --- | --- | --- | --- |
| `Motion.kt` stackPush | hand-made push: slide in from the right, old page drifts a quarter left and fades | 340 ms FastOutSlowIn | looks custom | replaced by shared axis X |
| `Motion.kt` FADE_THROUGH | fade out then in with a gap | 90 + 150 ms | gap, unused by root tabs | removed |
| `Motion.kt` FADE | fade for live video | 210 in, 120 out | duplicate of crossfade | merged into CROSSFADE |
| `Motion.kt` MODAL_UP / MODAL_DOWN | full-height slide up / down | 280 / 200 ms | too big a movement | fade plus 8 dp rise in, fast fade out |
| `DepthTransition` users (Settings, Sessions, hub folder page, agents chat, terminal shell, onboarding landing) | stackPush | 340 ms | custom look | shared axis X, identical everywhere |
| `ConnectTab` stage `AnimatedContent` | stackPush between scanner, onboarding, pairing, session | 340 ms | custom look | shared axis X; live video only crossfades |
| `SessionRoutes` route `AnimatedContent` | modal slide for paywall over the remote | 280 / 200 ms | oversized | modal fade and 8 dp rise |
| `PeeringNavHost` | tabs switch instantly | none | keep | unchanged |
| `PeeringScaffold` bottom bar | expandVertically / shrinkVertically | default spring | animates size each frame | fade in, fast fade out |
| `SessionHub` tab `Crossfade` | crossfade between Agents, Terminals, Files | 120 ms | fine | `Motion.fast()` |
| `SessionHub` switcher | fade and full-height slide from the top | 160 ms | oversized | fade and 8 dp drop in, fast fade out |
| `FloatingPanel` open / close | fade and quarter-height slide | 220 / 160 ms | oversized | fade and 8 dp rise in, fast fade out |
| `FloatingPanel` panel switch | fade plus rise, size spring | 160 / 90 ms | gap-prone, rising swap | crossfade only, size spring `Motion.spring()` |
| `RemoteChrome` controls and immersive button | default `fadeIn()` / `fadeOut()` (springs) | ~300 ms springs | inconsistent | `Motion.enter` / `Motion.leave` |
| `StatusPill` | float progress drives width, corner, alpha | 280 ms FastOutSlowIn | resize looked stiff | `Motion.spring()`, still read only in layout and draw |
| `SessionStatusBar` | unused animation imports | none | dead | imports removed |
| `FirstConnectionScreen` found hosts | default expand and fade | default | animates size | fade only |
| `FirstConnectionScreen`, `PairingCodeContent` | staggered `arrive()` fades on title and steps | 300 ms, delays up to 300 ms | entrance on first composition | removed |
| `WelcomeLanding` | staggered hero, copy, button with scale 0.96 and 28 dp rise | 300 ms, delays 60 to 300 | zoom and stagger | removed, page just appears |
| `PeeringMotion.kt` | token object and `arrive` modifier | various | dead after the above | deleted |
| `FloatingChips` | scale-in, staggered arrival, endless drift | 300 ms plus infinite 6980 ms | scale-in, infinite | static, page crossfade only |
| `TourStage` | crossfade between tour pages | 120 ms | fine | `Motion.fast()` |
| `PageDots` | dot width tween read in composition | 200 ms | recomposes per frame | `Motion.spring()` read in layout |
| Tour pager `animateScrollToPage`, dock pager `animateScrollToPage` | default spring | default | inconsistent | `Motion.spring()` |
| `FaqScreen` row | `animateContentSize` and chevron | default spring, 200 ms | fine in spirit | `Motion.spring()` and `Motion.standard()`, chevron rotated in a graphics layer |
| `HubLoadingRows` | endless alpha pulse | 900 ms reverse, infinite | infinite | static, fades in after 150 ms |
| `TerminalLoading`, `TerminalStarting` | spinner / ticking caret and dots (120 ms timer) | infinite | infinite | fade in after 150 ms, caret and dots still |
| `ThinkingRow` dots | sine wave on padding | 1200 ms, infinite | infinite, animates padding | three still dots |
| `Sheen` (headings) | one highlight crossing, switched off in code | 1600 ms | dead | removed, `HeadingBrush` constant |
| `RailPress`, `FileEntryRow` | hand-rolled press feedback (scale 0.9 / alpha 0.6) | 120 ms | duplicated | shared `pressFeedback` |
| Buttons, chips, plan card, relay card, source tiles | ripple on fills where it barely shows | ripple | no visible feedback | `pressable` |
| `TerminalListScreen`, `HubList` rows | `animateItem()` defaults (springs) | default | inconsistent | `listItemMotion()` on keyed rows |
| `PairingCodeCells` wrong-code shake | five 50 ms steps | 50 ms each | error feedback, short | kept |
| `PeeringSpinner` | Material `CircularProgressIndicator` | system | system control | kept |
| Hub activity open, close and back | system activity transition | system | correct | kept |
| `TerminalTabStrip`, `TranscriptList` `animateScrollToItem` | default scroll spring | default | follows content | kept |
