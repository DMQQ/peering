# Peering: the design system

The reference for building App Store screenshots, marketing art, or any new screen that has to
sit next to the ones in the app. Values are read from the shipping source, not from a spec that
once described it.

The two authorities are `MacCast/Theme.swift` (client) and `MacCastHost/Theme.swift` (Mac host).
When this document and those files disagree, the files are right and this document is stale.

Product names: **Peering** on iPhone, **Peering Host** on Mac. The repository is MacCast.

---

## 1. The world

Near-black stage. One soft light from above. No accent hue except a single state blue.

The palette is built out of **opacities of white** rather than colours, and that is a rule rather
than a preference. Every screen here is a frame around a picture, and the picture (a Mac's desktop,
whatever the user happens to be doing on it) is the only thing entitled to a colour. An accent
competing with the content is the one thing chrome must never do. Where a state needs emphasis it
gets brightness instead, which is quieter and survives every accessibility setting a hue does not.

Two exceptions, both deliberate:

- **The accent**, which marks "this one is on" and nothing else. It is system blue, chosen because
  it is already what every other control on the phone means by "selected", so it needs no learning.
- **A latency reading**, which is a measurement rather than a state and so is allowed a hue.

Both apps are dark by fiat, not by preference. The client pins `.preferredColorScheme(.dark)` in
twenty-odd places; the host pins the window appearance in `MacCastHostApp`. A host window that
followed a light Mac into a white palette would be a different product.

The same thinking is why the host's palette was moved off `Color.primary` and
`.windowBackgroundColor`. A semantic palette inherits from the *system*, so the window came out as
stock macOS grey with the frost of a settings panel, the user's accent sprayed across every sidebar
glyph, and fully saturated system green and red for state. The phone sitting next to it on the desk
was near-black with one blue in it. Two apps that are meant to read as one product were reading as a
product and a system utility.

---

## 2. Colour

### Client (`ColorPalette`)

| Token | Source | Hex | What it is |
|---|---|---|---|
| `backdrop` | `rgb(0.04, 0.04, 0.045)` | `#0A0A0B` | Everything sits on this |
| `ink` | `Color.white` | `#FFFFFF` | Selection, checkmarks, live indicators, anything "on" |
| `onInk` | `Color.black` | `#000000` | Drawn on top of a filled `ink` surface |
| `accent` / `selectedFill` | `Color.blue` | `#0A84FF` | The one colour. "This one is on", nothing else |
| `danger` | `rgb(0.98, 0.45, 0.40)` | `#FA7366` | Something that did not work |
| `caution` | `rgb(0.97, 0.75, 0.35)` | `#F7BF59` | A tool being careful, dimmer than `danger` |
| `surface` | `white @ 7%` | | A resting surface, rows and chips |
| `glassTint` | `backdrop @ 70%` | | Wash under a frosted surface below iOS 26 |

`accent` renders as `#0A84FF` because both apps are dark-pinned. It is `Color.blue`, not a literal,
so it tracks the system's dark-mode value.

`backdrop` is near-black rather than pure black on purpose: a pure `#000` next to a video's own
blacks makes the picture look inset in its own frame.

### Host (`HostPalette`)

| Token | Source | Hex | What it is |
|---|---|---|---|
| `backdrop` | `rgb(0.04, 0.04, 0.045)` | `#0A0A0B` | The stage, the phone's own value exactly |
| `surface` | `white @ 4.5%` | | A panel resting on the stage |
| `raised` | `white @ 8.5%` | | A row, tile or hover inside a panel |
| `ink` | `white` | `#FFFFFF` | Selection, a live session |
| `muted` | `white @ 62%` | | Neither good nor bad; the resting tone for labels |
| `faint` | `white @ 46%` | | Idle, absent, switched off, timestamps |
| `hairline` | `white @ 8%` | | A divider, or a row that needs an edge but no lift |
| `accent` | `Color.blue` | `#0A84FF` | Fixed, so both apps mark "on" the same way |
| `success` | `rgb(0.36, 0.85, 0.55)` | `#5CD98C` | Operational feedback |
| `caution` | `rgb(0.97, 0.71, 0.30)` | `#F7B54C` | Operational feedback |
| `danger` | `rgb(0.98, 0.45, 0.40)` | `#FA7366` | Operational feedback |

`faint` is held at **4.6:1** against the stage rather than taken to where it looks right, because
it is what a timestamp and an inactive glyph are drawn in, and "quiet" is not a licence to be
unreadable. Anything quieter belongs in `muted`.

State colours are tuned down from the system tones on purpose. `systemGreen` and `systemRed` are
mixed to survive a grey background; on this one they are the loudest thing in the window, and a dot
that shouts louder than a failure's own sentence is a dot with the wrong job.

Two gradient constants matter and are easy to miss:

```swift
// Host: the stage's own light, hue-free. Two accent washes in one window is how a dark app
// still reads as blue. Light from above says where the window is lit; colour says nothing.
stageLight = LinearGradient([white @ 3.5%, .clear], .top → .center)

// Host: the lit edge of a raised surface. Brighter along the top and fading down the sides is
// how a surface catches light, and it is the whole difference between a rectangle drawn on the
// background and a panel sitting in front of it.
litEdge = LinearGradient([white @ 18%, white @ 4%], .top → .bottom)
```

### The backdrop's light

`AppBackdrop` is the single shared backdrop for every root tab. Not a flat colour:

```swift
ZStack {
    ColorPalette.backdrop
    RadialGradient(
        colors: [.white.opacity(0.07), .clear],
        center: .top,
        startRadius: 0,
        endRadius: 460
    )
}
.ignoresSafeArea()
```

That gradient is the whole difference between a flat page and a lit stage. Put it in every
screenshot.

### Latency readings

`ColorPalette.reading(_:)` is the one place the palette breaks its own rule, and it says so:
brightness where an accent would have been a traffic light, except that three shades of white at
arm's length are one shade, and the whole point of showing a latency figure is to be noticed.

| Milliseconds | Colour |
|---|---|
| `< 40` | `.green` |
| `< 120` | `.yellow` |
| `>= 120` | `.orange` |

A red latency number would shout about something the user can do nothing about, which is why the
top of the range is orange.

---

## 3. Type

Two voices, and they never swap jobs.

### Display face: names only

SF Serif, which is New York. Always bold. Declared once per app, in `DisplayFont.display(_:)` on the
client and `HostDisplayFont.display(_:)` on the host, because a face is a decision and not a value.
Four separate `design: .serif` spellings are four chances for one of them to be left behind the day
the app picks a different face, and what that looks like is one heading in the app that is not like
the others.

Reached for anything set as a *name* rather than as a label: the wordmark, a screen's title, the
headings of the tour, the host's sidebar wordmark.

| Where | Size | Tracking |
|---|---|---|
| Screen title (`TabScreenHeader`) | 34pt bold serif | `-1.2` |
| Tour headings | `.largeTitle` bold serif | `-1` |
| The wordmark, resting | 60pt | `-2.2` |
| The wordmark, folded | 82pt | `-3.2` |

The wordmark is painted at **78% white**, not full. That is the effect's doing rather than the
palette's: light crossing light is nothing, so a name already at the maximum leaves the sweep
nowhere to go.

### System face: everything else

SF Pro. The distribution is dominated by `.subheadline` (15) and the caption sizes.

| Role | Spec |
|---|---|
| Row title | `.subheadline.weight(.medium)` |
| Emphasised row title | `.subheadline.weight(.semibold)` |
| Screen title's tagline | `.subheadline`, `.secondary` |
| Card footer | `.caption`, `.tertiary` |
| Readings and numbers | `.caption2.monospaced()` |
| Rail captions | 9pt (the floor) |
| `SectionLabel` | 10pt semibold, `.rounded`, tracking `1.1`, uppercase, `.secondary` |
| `Controls.sectionLabel` | 12pt semibold, tracking `0.2`, with an 11pt semibold SF Symbol |

Numeric sizes across the two apps run from 8 to 48, clustered at 10, 11, 12, 13 and 15.

**One voice for every label in the app** rather than each screen choosing its own size. A headline
in one place and a caption in another is the kind of inconsistency nobody can name and everyone can
see.

The 9pt rail captions are why `glassTint` is as heavy as it is. Over a blank document a thin frost
lands within a few points of `ink` and those captions stop reading entirely, so the wash is opaque
enough to close that range, at the cost of letting the picture through less.

### Why the display face never sets a label

One of these is a screen's name and the other is a sentence about it. Setting both in the display
face makes the tagline read as a second title.

---

## 4. Surfaces

The rule the whole thing turns on: **cards are outlined, never filled.**

A card used to carry `ColorPalette.surface`, white at 7%, and white at 7% over a near-black backdrop
is not a raised surface, it is a grey one. Every card on every screen became the same flat grey
panel, one shade lighter than the page it sat on and one shade darker than the rows inside it, so
the three levels a card needs (page, card, row) collapsed into three greys a few points apart. That
is the shape that reads as a mistake without anyone being able to name it.

Outlined instead, the card keeps its edge from the stroke and its depth from the backdrop's own
light.

### Card

```swift
.padding(16)
.background { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.clear) }
.overlay {
    RoundedRectangle(cornerRadius: 24, style: .continuous)
        .strokeBorder(
            LinearGradient(
                colors: [.white.opacity(0.20), .white.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 1
        )
}
```

A gradient rather than one flat opacity, because brighter along the top edge and fading down the
sides is how a raised surface catches light. It costs a gradient and no colour.

`cardBackground()` is the shape without the padding, for a card built out of more than one block:
the Connect screen's two halves are each padded around a divider that runs the full width of the
card, and a single 16-point inset would pull that divider in to the padding instead of leaving it at
the card's edge.

### Row

The same trick one level down and one step quieter, so a row reads as sitting *on* the card rather
than cut into it. This is the only filled surface in the app.

```swift
.background {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(LinearGradient(
            colors: [.white.opacity(0.09), .white.opacity(0.045)],
            startPoint: .top,
            endPoint: .bottom
        ))
}
.overlay {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.white.opacity(0.07))
}
```

### Divider

`Divider().overlay(.white.opacity(0.07))`, and never after the last row. A rule under the bottom row
of a card is a line with nothing on the other side of it.

### Panels (host)

```swift
// hostPanel
background(surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay { strokeBorder(litEdge, lineWidth: 1) }
    .shadow(color: .black.opacity(0.34), radius: 16, y: 7)
```

The host's live stream is the one object in the window that is not a panel, and it gets the one
place worth spending a second edge on:

```swift
// hostPrimaryPanel: a double bezel rather than a single stroke
padding(3)
    .background(surface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
    .overlay { strokeBorder(litEdge, lineWidth: 1) }              // the softer rim outside
    .overlay { strokeBorder(hairline, lineWidth: 1).padding(3) }  // the crisp inner edge
    .shadow(color: .black.opacity(0.5), radius: 28, y: 12)
```

### Glass (in-session chrome)

One modifier behind the whole thing, `glassSurface(in:interactive:)`, so the deployment floor is a
build setting rather than twenty-five edits.

```swift
if #available(iOS 26.0, *) {
    glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
} else {
    shape.fill(.ultraThinMaterial)
        .overlay(shape.fill(ColorPalette.glassTint))
        .overlay { shape.strokeBorder(hairline, lineWidth: 1) }   // the same 20% → 5% gradient
        .environment(\.colorScheme, .dark)
}
```

The two branches are not the same material and do not pretend to be. Glass samples what is behind it
and adapts to it; a `Material` blurs it and stays put. The fallback therefore carries `glassTint` over
the frost, because these panels sit on a picture that can be anything, and an unmodified frost over a
white document turns a caption into a smudge. What the fallback cannot reproduce is `interactive`:
glass takes the shape of the press and a material does not.

If you are mocking session chrome for a screenshot, the **fallback** is the safer thing to draw. It
is heavier and more predictable than real glass over an arbitrary desktop.

### Icon tile

The subject of a row: one glyph in a rounded tile. Used at three sizes, and it is one shape at three
scales rather than three shapes that happen to look similar.

| Use | Size | Glyph | Corner | Fill |
|---|---|---|---|---|
| `IconTile` (default) | 42 | `size * 0.405`, medium | `size * 0.286` | `ink @ 12%` |
| `Controls.icon` (a row's control) | 28 | 13pt semibold | 8 | `tint @ 14%` |

### Plan badge

A capsule carrying a plan's name, drawn *on* a gated control and never in its place:

```swift
Text(capability.minimumPlan.badge)          // RELAY / PLUS / PRO
    .font(.system(size: typeSize, weight: .bold))
    .tracking(tracking)
    .foregroundStyle(ColorPalette.accent)
    .padding(.horizontal, horizontal)
    .padding(.vertical, vertical)
    .background(ColorPalette.accent.opacity(0.18), in: Capsule())
```

| Form | Type size | Tracking | Horizontal | Vertical |
|---|---|---|---|---|
| `.control` (a peer of the control) | `max(9, diameter * 0.32)` | 0.5 | `diameter * 0.3` | `diameter * 0.17` |
| `.corner` (a mark on the control) | `max(8.5, min(10, diameter * 0.25))` | 0.4 | 4 | 1.5 |

The corner mark hangs **6pt** off the corner it is pinned to, in both axes. Below about four it reads
as sitting inside the control, where the control's own glyph lives. Above about eight it reaches the
layout's tightest gaps: the 8 points between two chips in the terminal deck, and the 6 points between
the switch rows in Settings.

A gated control is drawn as itself, in its own shape and with its own glyph, at **60% opacity** and
inert. Never a padlock, never a badge in the control's place.

---

## 5. Spacing and shape

### In-session chrome (`ChromeMetrics`)

One place, because "even" is only ever true by construction. The moment the rail and the wheel each
carry their own numbers they drift, and the drift is exactly what reads as sloppy.

| Token | Value | Note |
|---|---|---|
| `panelWidth` | 54 | Every panel, so both columns line up top to bottom |
| `cornerRadius` | 20 | Every panel, in every orientation |
| `pillCollapsedRadius` | 30 | Half the collapsed pill's height: a stadium |
| `pillExpandedRadius` | 26 | Keeps the softened look at a size that leaves its contents alone |
| `railPadding` | 4 | Above the first button, below the last, and the same as the gap either side |
| `railSidePadding` | 4 | Rail edge to button edge, horizontally |
| `edgeInset` | 8 | Safe area to the first panel, on all three edges |
| `bottomInset` | 22 | Larger, because the thumb already rests across the bottom |
| `panelGap` | 8 | Between two stacked panels in one column |
| `buttonGap` | 2 | Between two buttons inside one panel |
| `panelPadding` | 5 | Above the first and below the last item inside a panel |
| `buttonHeight` | 62 | Taller than wide: a square button is a circle in a capsule rail |
| `wheelHeight` | 120 | The whole wheel, chevrons and padding included |
| `quickKeySize` | 60 | A standalone key, hit with a thumb already on the joystick |

Neither pill radius is `capsule`, and that is a correction. A capsule's corner is half its height, so
a three-row pill grew a curve big enough to cut into the controls along its own top and bottom edges.
The pair of numbers is what makes the two states read as one object changing size.

### The portrait dock

| Token | Value |
|---|---|
| `dockColumns` | 5 (row three is the five navigation keys, one per column, nothing left over) |
| `dockExpandedRows` | 3 |
| `dockToggleWidth` | 52 |
| `dockCollapsedHeight` | 70 (derived: `buttonHeight + railPadding * 2`) |
| `dockExpandedGridHeight` | 190 (derived: `62 * 3 + 2 * 2`) |
| `dockExpandedHeight` | 198 |
| `dockPageDotsHeight` | 10 |
| `dockDotsGap` | 6 |
| `dockStandingHeight` | 214 (the card, the gap, and the dots: what a panel above must clear) |
| `dockCollapsedRadius` | 35 (half the closed height: a stadium) |
| `dockExpandedRadius` | 28 |
| `dockWidthFraction` | 0.9 |

The page dots are drawn *under* the card rather than in it, which is what makes the glass exactly as
thick as its buttons. They are not decoration: a shut dock pages as well, and without them the swipe
is invisible until somebody happens to try it.

The dock spans 90% of the width rather than running edge to edge, because a bar running the full
width would be the one piece of chrome that was a different kind of object from the panels, which all
float with a margin around them.

### Host

| Token | Value |
|---|---|
| `panelRadius` | 18 |
| `controlRadius` | 10 |

### Settings-shaped screens

| Element | Value |
|---|---|
| Card | padding 16, corner 24 |
| Rows inside a card | `VStack(spacing: 12)` after the section label |
| A single row | `HStack(spacing: 11)`, glyph, name, `Spacer(minLength: 10)`, control |
| Row vertical padding | 2 |
| Picker's value tint | `white @ 72%` (a picked value is not a state) |

---

## 6. Motion

Two speeds at minimum, because giving them the same timing is what makes an interface feel
mechanical: a thing arriving on screen wants to be seen arriving, and a thing reacting under a finger
wants to have already reacted.

| Token | Curve | For |
|---|---|---|
| `settle` | `spring(response: 0.34, dampingFraction: 0.84)` | Panels, overlays, anything appearing |
| `tap` | `smooth(duration: 0.18)` | A control changing state |
| `arrive` | `spring(response: 0.52, dampingFraction: 1)` | A screen arriving: the Connect header, the cards, a tour page |
| `travel` | `timingCurve(0.3, 0.6, 0.32, 1, duration: 0.88)` | The Connect header's leftward journey |
| `rise` | `timingCurve(0.55, 0.12, 0.32, 1, duration: 0.88)` | Its upward one |
| `morph` | `spring(response: 0.4, dampingFraction: 0.68)` | The status pill opening into the panel |

`arrive` is the only critically damped spring here. `settle` and `morph` are allowed their give
because both are moving a shape the user is already looking at, and the overshoot is what says the
thing has weight. An entrance is different: it is a whole screen arriving in a dozen pieces, each on
its own delay, and give in every one of them means the last frames disagree about which way is down.

`travel` and `rise` are two curves rather than one, and they share a duration. A straight line
between two points is the one path that reads as a transition rather than as something moving; two
curves of different lengths are two arrivals, and the mark would land, move again, and land.

Press feedback on a control:

```swift
// RailButtonStyle: scale 0.9, opacity 0.6, easeOut 0.12
// A host button: scale 0.98, opacity 0.85, spring
```

Host motion: `hover` `spring(0.24, 0.86)`, `press` `spring(0.18, 0.78)`, `state` `spring(0.36, 0.88)`.

The wordmark's light sweeps once every **4.2s**, taking **1.6s** to cross, as a band **34%** of the
name's width. The pause at either end is what keeps this a detail rather than a strobe: a sweep that
restarts the moment it leaves is a loop, and a loop is a thing the eye starts waiting for.

---

## 7. The phone frame

The onboarding `PhoneStage` and the marketing site share one drawing, and the numbers are exact. The
frame is the constant and the screen inside it is the variable, so each page's picture lands inside
the app's own shape rather than beside a different one.

| Token | Value |
|---|---|
| Aspect | `603 / 1311` |
| Bezel | `10 / 290` of screen width (**3.45%**) |
| Body corner | `0.148` of body width |
| Screen corner | `0.128` of screen width |
| Body fill | `#202023 → #101012`, top to bottom |
| Rim | `white 30% → 8%`, 1pt, drawn *inside* the body |
| Shadow | `black @ 55%`, radius 22, y 10 |
| Island | `30%` of screen width, `3.8%` of screen height, top padding `1.9%`, pure black |

The bezel is proportional rather than fixed, and that is the whole point. The site's mockup is a
310-point body with 10 points of padding; the tour draws the same device at whatever height the stage
can spare, and the same fixed 10 points was **4.8%** of the picture there against the **3.4%** the
site draws. A fixed border in one place and a derived one in the other is two devices, and the fat one
is the one nobody drew.

The body is drawn as dark as a body and no darker. It was once white at 18% fading to 5%, which over
a near-black backdrop is not a device but a bright band, and a bright band is what the eye measures
when it decides how thick a frame is. An iPhone seen face on in a dark room is the opposite
arrangement: a bezel barely distinguishable from the display it holds, and one machined highlight
along the outside.

The island is drawn by the frame rather than expected in every screenshot. A screenshot of this app
already has one (its own is black on a black backdrop), and the two land in the same place.

### The pair (Mac and phone)

The tour's first page and the site's hero draw the same composition: the Mac, with the phone standing
in front of its right-hand edge, the Mac lifted a little because of the two the near one is the low
one. Every number is a fraction of the Mac's display width, so the pair keeps its balance at whatever
size the stage can spare.

| Token | Value |
|---|---|
| Phone screen width | `0.46` of the Mac's display width |
| Overlap | `0.14` of the display width, drawn as a negative gap |
| Mac lift | `0.035` of the display width |
| Display height | one division per limit, the tighter wins |

The phone fraction is **not** the true one, and `styles.css` says why at length: an honest 14-inch
MacBook beside an honest iPhone draws the phone at about half the width it is given here, and a
screenshot nobody can read is not a screenshot. It is the fraction that keeps both pictures legible,
which is what the picture is for.

Both limits are live in a way the Mac alone never sees. The Mac by itself is width-limited in the
tour's stage, so its height never had to be solved for; the pair has to clear the phone's height,
which is the taller of the two, as well as the extra width the phone adds across the Mac's right
edge.

### The Connect header

| Token | Resting | Open |
|---|---|---|
| Name size | 60 | 82 |
| Tracking | `-2.2` | `-3.2` |
| Mark size | 72 | 136 |
| Gap | 16 | 26 |
| Inset | 18 | 18 |
| Top gap | 12 | 12 |
| Header height | 202 | 202 |

---

## 8. Copy voice

From the strings that ship:

- **"Your Mac, in your pocket."** The one-line pitch.
- Sentence case everywhere except `SectionLabel` and plan badges, which are uppercase.
- Names of objects are capitalised when they are the product's own nouns: Connect, Servers, Sessions,
  Settings, Nearby, Trusted Macs, Another network, Recent connections.
- A control says what it does, in the app's own words, and a failure says what failed and what to do.
  The paywall's copy is written in fewer words than the marketing instinct asks for.

---

## 9. Where the tokens live

| File | Owns |
|---|---|
| `MacCast/Theme.swift` | `ChromeMetrics`, `Motion`, `ColorPalette`, `AppBackdrop`, `DisplayFont`, `AnimatableDisplay`, `IconTile`, `Wordmark`, `TabScreenHeader`, `SectionLabel`, `cardSurface()`, `rowSurface()`, `glassSurface()` |
| `MacCast/SharedControls.swift` | `Controls` (sectionLabel, card, row, toggle, picker, icon, divider), `PlanLock`, `PlanLocked` |
| `MacCast/InputControls.swift` | `RailButtonStyle`, the rail buttons |
| `MacCast/OnboardingView.swift` | `PhoneStageMetrics` / `PhoneDrawing` / `PhoneStage`, `MacStageMetrics` / `MacDrawing`, `MacAndPhoneStage` + `MacAndPhoneMetrics`, `PlanChoice` |
| `MacCastHost/Theme.swift` | `HostPalette`, `HostDisplayFont`, `HostMotion`, `hostPanel()`, `hostPrimaryPanel()`, `HostHostingButtonStyle` |
| `MacCastKit/Sources/MacCastKit/PlanAccess.swift` | The plan ladder: which capability is free, and each plan's badge string |

`HostPalette` and `DisplayFont` are deliberate copies of the client's rather than shared constants.
Sharing them would mean moving UI values into `RemoteCore`, the wire protocol, and a UI dependency
there would outlive any benefit from saving them.

Two habits worth keeping when adding to any of this:

1. **Derive, do not restate.** `dockCollapsedHeight` is `buttonHeight + railPadding * 2`, not `70`. The
   number and the thing it has to contain cannot drift apart if there is only one of them.
2. **Lift on the second use, not the third.** Two copies of one surface style start drifting at the
   first tweak. `IconTile` exists because a second screen copied a body out by hand rather than
   reaching for it.
