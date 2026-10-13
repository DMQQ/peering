# Android UI audit: every clickable element

Scope: `android/app/src/main/kotlin`. Status is as found at the start of the audit: works, partly (the tap does something but a path around it is dead or wrong) or dead. The last column says how it is covered after the repairs. "T:" is a JVM test, "D:" a check on the phone (RF8NC0J9BQB, debug build), "S:" the structural scan `EmptyCallbackScanTest`.

Rule since this audit: no empty lambda and no no-op default in production UI code. Callbacks are required; a legitimately optional one is nullable and its element is hidden when it is absent. `EmptyCallbackScanTest` enforces it with an empty allow-list.

## First run (OnboardingRoute, TourScreen)

| Screen | Element | Handler | Expected (iPhone) | Status | Covered by |
|---|---|---|---|---|---|
| Landing | See how it works | `presenter::next` | Opens the tour | works | T: OnboardingPresenterTest; D: walkthrough |
| Landing | Skip | `presenter::skip` | Leaves the first run | works | T: OnboardingPresenterTest; S |
| Tour pages 1 to 7 | Next | pager scroll | Next page | works | D: walkthrough, 7 taps |
| Tour pages 1 to 7 | Skip | `presenter::skip` | Jumps to the plans | works | T: OnboardingPresenterTest |
| Tour | Swipe and system back | pager, `BackHandler` | Previous page, landing, then leaves | works | T: OnboardingPresenterTest (back) |
| Tour | Page dots | display only | Indicator | works (not tappable on iPhone either) | none needed |
| Tour page 2 | Download address link, copy chip | `DownloadLink` | Opens the page, copies the address | works | S |
| Plans | Free card | `setFree(true)` | Selects Free | works | T: PlansActionTest |
| Plans | Paid plan cards | `plans.select` | Selects the plan | works | T: PaywallPresenterTest |
| Plans | Primary button, Free chosen or nothing to buy | `onFinished` then `presenter.finish` | Persists the flag, opens the main app | works | T: PlansActionTest, OnboardingPresenterTest (finish); D: Start using Peering reached Connect |
| Plans | Primary button, paid plan chosen | `plans.buy` then finish on PURCHASED | Starts the purchase, continues when bought | works | T: PaywallPresenterTest, PlansActionTest |
| Plans | Billing unavailable | text under Free | Explains why there are no prices | partly (generic text, reason dropped) | D: plans page; T: PaywallPresenterTest |
| Plans | Retry text | `plans::load` | Asks the store again | works | D: tapped, page stable |
| Plans | Restore purchases | `plans::restore` | Restores or says there is nothing | works | T: PaywallPresenterTest; D: "No purchases to restore" shown |
| Plans | Privacy Policy, Terms of Use | `LocalUriHandler` | Opens the web page | works | S |

## Connect tab (ConnectTab, ConnectRoute, FirstConnectionScreen)

| Screen | Element | Handler | Expected | Status | Covered by |
|---|---|---|---|---|---|
| Connect | Nearby host row | `actions.onPair` | Starts pairing with it | works | T: ConnectPresenterTest |
| Connect | Nearby host row forget | was `onForget = {}` | None (an unpaired computer has no menu) | partly (inert parameter) | S; the menu is now absent when `onForget` is null |
| Connect | Connect by address chip | sheet | Opens the address sheet | works | D: Connect screen |
| Address sheet | Connect | `presenter::connectToAddress` | Dials the address, starts pairing | works | T: ConnectAddressTest |
| Address sheet | Dismiss | `onDismiss` | Closes | works | S |
| Connect | Search again | `presenter::searchAgain` | Restarts discovery | works | T: ConnectPresenterTest |
| Connect | Open Wi-Fi settings | `rememberConnectActions` | Opens system Wi-Fi settings | works | S |
| Connect | Pair with a computer elsewhere | sheet | Opens the device ID sheet | works | D: Connect screen |
| ID sheet | Text field, Go key, Pair | `entry.onTextChanged`, `entry.submit` | Validates, pairs | works | T: HostIdEntryPresenterTest |
| ID sheet | Paste | clipboard | Fills the field | works | T: HostIdEntryPresenterTest |
| ID sheet | Scan | `onScanRequested` | Opens the scanner | works | T: HostIdEntryPresenterTest (onScanned) |
| ID sheet | Dismiss | `onDismiss` | Closes | works | S |
| Connect | Trusted host row | `actions.onConnect` | Connects, opens the session | works | T: ConnectPresenterTest |
| Connect | Trusted host menu, Forget | `presenter::requestForget` | Asks, then forgets | works | T: ConnectPresenterTest |
| Forget alert | Forget, Cancel, outside tap | `confirmForget`, `cancelForget` | Forgets or keeps | works | T: ConnectPresenterTest |
| First connection | Install link | `LocalUriHandler` | Opens the download page | works | S |
| First connection | Nearby choice | `actions.onPair` | Starts pairing | works | T: ConnectPresenterTest |
| First connection | Enter ID, Enter address | sheets | Open the sheets | works | D: not shown with a trusted host |
| First connection | Later | `firstConnectionDismissed` | Shows the host list | works | S |
| First connection | Steps 4 and 5 | were `{}` content | Display only | partly (empty lambdas) | S; content slot is now nullable |
| Scanner | Close (X), system back | `onClose` | Returns to the screen it came from | works | S |
| Scanner | Allow camera, Open settings | `ScanAction` | Asks, or opens app settings | partly (default `{}` action) | S; the action is now one required value |
| Pairing | Back arrow while connecting or entering | `presenter::cancel` | Sends pairConfirm accepted=false, closes, returns to Connect | works | T: PairingCodePresenterTest |
| Pairing | Cancel pairing link | `presenter::cancel` | Same | works | T: PairingCodePresenterTest |
| Pairing | Back arrow and Back button after a failure | `onFinished` | Closes the connection and returns to Connect | partly (left the failed session open) | T: PairingCodeScreenTest |
| Pairing | Code cells | `presenter.submitCode` | Checks six digits | works | T: PairingCodePresenterTest |
| Pairing | Scan the code instead | `onScanRequested` | Opens the scanner | works | T: PairingCodePresenterTest |
| Pairing | Back after Done | `onFinished` | Returns to Connect, keeps the connection | works | T: PairingCodeScreenTest |
| Session | System back | `BackHandler` | Leaves the session screen | works | S |

## Session (SessionScreens, RemoteRoute)

| Screen | Element | Handler | Expected | Status | Covered by |
|---|---|---|---|---|---|
| Remote | Keyboard key | `keyboardShown` | Shows the function keys and the soft keyboard | works | T: KeyboardPresenterTest |
| Remote | Menu key | `hubOpen` | Opens the hub sheet | works | T: HubPresenterTest |
| Remote | Function keys, modifier bar | `keyboard.onFunctionKey`, `onModifierTap` | Sends keys, latches modifiers | works | T: FunctionKeyTest, StickyModifiersTest, KeyboardPresenterTest |
| Remote | Canvas touch | `RemoteCanvasPresenter` | Pointer, scroll, pinch | works | T: RemoteCanvasPresenterTest |
| Hub sheet | Sources | `sourcesOpen` | Opens the sources sheet | works | T: HubPresenterTest |
| Hub sheet | Agents, Files | `model.onHubEntry` | Opens the screen, or says it is unavailable | works | T: RemoteStatesTest |
| Hub sheet | Quality | `qualityOpen` | Opens the quality sheet | works | T: QualitySheetPresenterTest |
| Hub sheet | Disconnect | `onDisconnect` | Ends the session, returns to Connect | works | T: SessionHolderTest |
| Hub sheet | Dismiss | `onDismiss` | Closes | works | S |
| Sources sheet | Source tile | `presenter.choose` | Switches the source | works | T: SourcesPresenterTest |
| Quality sheet | Quality row | `presenter.choose` | Sets quality, opens the paywall when it needs relay time | works | T: QualitySheetPresenterTest |
| Session | Relay time spent | `PaywallRoute` | Shows the paywall | works | T: RelayAllowanceTrackerTest |
| Agents hub | New chat | `presenter::beginNewChat` | Opens the agent choice | works | T: AgentsHubPresenterTest |
| Agents hub | Agent choice row, dismiss | `chooseAgent`, `cancelNewChat` | Opens the folder step, or closes | works | T: AgentsHubPresenterTest |
| Agents hub | Folder rows, Up, search, hidden switch, recents | `folders.*` | Browses | works | T: FolderPickerTest |
| Agents hub | Use this folder | `startInChosenFolder` | Starts the chat and opens it | partly (the chat started but the hub stayed) | T: AgentsHubPresenterTest |
| Agents hub | Folder back | `backToAgents` | Returns to the agent choice | works | T: AgentsHubPresenterTest |
| Agents hub | Session card, End | `openSession`, `closeSession` | Opens, ends | works | T: AgentsHubPresenterTest |
| Chat | Back | `onBackToList` | Returns to the hub | works | S |
| Chat | Tool call card | `toggleTool` | Expands | works | T: TranscriptPresenterTest |
| Chat | Jump to latest | `followLatest` | Scrolls to the end | works | T: TranscriptPresenterTest |
| Chat | Allow, Deny, option, Back | `ApprovalPresenter` | Answers the approval | works | T: ApprovalPresenterTest |
| Chat | Send, Stop, attach, detach | `ComposerPresenter` | Sends, interrupts, attaches | works | T: ComposerPresenterTest |
| Chat | Permission mode, model menus | `setPermissionMode`, `setModel` | Changes them | works | T: ComposerPresenterTest |
| Files | Entry row, breadcrumb, Up, Refresh | `FileListPresenter` | Browses | works | T: FileListPresenterTest |
| Files | Sort menu, hidden switch | `setSort`, `toggleHidden` | Sorts, toggles | works | T: FileListPresenterTest |
| Files | Preview close, Download, Cancel | `FilePreviewPresenter` | Closes, saves, cancels | works | T: FilePreviewPresenterTest |
| Paywall | Plan row, Buy, Try again | `select`, `buy`, `load` | Choose, purchase, retry | works | T: PaywallPresenterTest |
| Paywall | Restore | `presenter::restore` | Restores or explains | works | T: PaywallPresenterTest |
| Paywall | Not now | `onDismiss` | Returns | works | S |
| Allowance spent | See plans, Not now | `onSeePlans`, `onDismiss` | Opens the plans, returns | works | T: AllowanceSpentPresenterTest |

## Sessions, FAQ and Settings tabs

| Screen | Element | Handler | Expected | Status | Covered by |
|---|---|---|---|---|---|
| Sessions | Navigation item | `navigateTo` | Shows the tab | works | T: PeeringDestinationTest; D: tab bar |
| Sessions | Session in progress | `SessionScreens` | Same screens as Connect | works | S |
| FAQ | Row | `open` toggle | Expands the answer | works | T: FaqEntriesTest |
| Settings | Stream quality radios | `chooseStreamQuality` | Saves the choice | works | T: SettingsPresenterTest |
| Settings | Trusted host Forget | `requestForget` | Asks, then forgets | works | T: SettingsPresenterTest |
| Settings | Forget alert | `confirmForget`, `cancelForget` | Forgets or keeps | works | T: SettingsPresenterTest |
| Settings | See plans | `plans = true` | Opens the paywall, back returns | works | S |
| Settings | Legal rows | `onOpenLegal` | Opens the page in the app | works | S |
| Legal page | Link rows | `onOpenWebPage` | Opens the browser | works | S |
| Navigation bar | Connect, Sessions, FAQ, Settings | `onSelect` | Switches tab | works | T: PeeringDestinationTest; D: tab bar |

## Kit controls (no handler of their own)

`PrimaryButton`, `InkButton`, `QuietButton`, `TonalButton`, `LinkButton`, `CapsuleChip`, `CircleIconButton`, `MenuItem`, `PeeringSheet`, `PeeringAlert`, `PeeringSwitch`, `ControlRow`, `ControlToggle`, `PeeringRow`, `KeyCap`, `PeeringTextField` pass their callback through; none has a default. `ControlRow` and `GuideStepRow` slots were `= {}` and are now nullable.

## Debug previews

`ui/debug/DebugPreview.kt` rendered screens with `{}` actions. They now log what was tapped, so a preview tap is visible in logcat under `PeeringPreview`.

## Device checks (debug build, RF8NC0J9BQB)

Run with the first-run flag cleared through `--ez reset_first_run true` (debug builds only). Landing, seven Next taps and the plans page, Restore purchases ("No purchases to restore"), Retry text, and Start using Peering reaching Connect were walked in order. After that: the address sheet and its back dismiss, the device ID sheet, the trusted host menu, the FAQ tab and an expanded row, Settings, See the plans and its back, and the tab bar. The flag was left true, as it was found. Not done on the phone: pairing and cancel against a Mac (a stray tap connected a session to the owner's Mac once and was left by Back), forgetting a host, scanner, session hub, agents and files, and paid plan purchase (Play lists no products for this app).
