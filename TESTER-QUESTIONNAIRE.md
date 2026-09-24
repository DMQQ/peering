# Peering: tester questionnaire

For anyone who has spent at least one session driving their Mac from the phone. Takes about
ten minutes. Type your answers under each question, or reply in the same order by email if that
is easier.

Two things worth saying before the questions:

- **Be blunt.** "It was fine" tells me nothing. What you found annoying, what you assumed would
  work and didn't, and what you gave up on are the answers worth having. Nothing here is a
  compliment contest.
- **Skip freely.** If you never used a feature, write X or skip it. A guess is worse than a blank,
  because I will act on it.

Rating scales in this document:

| Scale | 1 | 3 | 5 | X |
|---|---|---|---|---|
| Fit and feel | unusable | usable, but it got in the way | as good as sitting at the Mac | didn't try it |
| Agreement | strongly disagree | no opinion | strongly agree | not applicable |

---

## A. You, and how you use it

**1. Which Mac are you connecting to?** (Apple silicon or Intel, laptop or desktop; the model name
is ideal)

**2. Which version of macOS is on it?**

**3. Which iPhone, and which version of iOS?**

**4. When you use Peering, where are you?**
- [ ] On the same network as the Mac
- [ ] Away from it, over the internet
- [ ] Both, roughly equally
- [ ] Only tried one so far (say which)

**5. How long have you been using it?**
- [ ] Today was my first session
- [ ] Under a week
- [ ] A few weeks
- [ ] Longer

**6. Describe the last thing you actually did with it.** The specific task, not the category. "Fixed
a deploy from a cafe" is useful; "remote work" is not.

---

## B. Getting it running

**7. Did you get a working picture on the phone today?**
- [ ] Yes, first try
- [ ] Yes, after sorting something out
- [ ] No

**8. Roughly how long from opening the Mac app to seeing your desktop on the phone?**
- [ ] Under 2 minutes
- [ ] 2 to 5 minutes
- [ ] 5 to 15 minutes
- [ ] Longer
- [ ] Never got there

**9. The Mac asks for Screen Recording permission, and sometimes Accessibility too. How clear was
what you had to do?**
- [ ] Completely clear
- [ ] I worked it out
- [ ] I needed help or a search

**10. Anything in install, pairing or permissions where you had to guess or look something up?**

**11. Have you ever had to re-grant a permission, or seen a connection fail because of one?** If
yes: did the app make it obvious what had gone wrong?
- [ ] Never happened
- [ ] Happened, and the app explained it
- [ ] Happened, and I had to work it out myself

---

## C. The picture

Rate each row. X if you did not look at this closely.

| | 1 | 2 | 3 | 4 | 5 | X |
|---|---|---|---|---|---|---|
| Overall picture quality | | | | | | |
| Sharpness: can you read text without zooming | | | | | | |
| Smoothness while things move (scrolling, dragging windows, video playing) | | | | | | |
| The pointer's own movement | | | | | | |
| Colour, versus the Mac | | | | | | |
| Zooming in and out, and fit-to-screen | | | | | | |

**12. Any of these, or none?** Tick whatever you saw.
- [ ] Tiles arriving late after zooming out, the canvas black or empty for a moment
- [ ] A flicker about a second after zooming in, as if the wrong window were showing
- [ ] Blur that clears after a moment
- [ ] A picture that stops updating until I touch something
- [ ] None of the above

**13. If you used it both on your own network and away from it, how did the two compare?**

**14. Anything else about the picture that annoyed you?**

---

## D. Driving the Mac

Rate each row. X if you did not try it.

| | 1 | 2 | 3 | 4 | 5 | X |
|---|---|---|---|---|---|---|
| Tapping a small thing accurately (a button, a menu item, a tab) | | | | | | |
| Typing, including shortcuts like Cmd+C | | | | | | |
| Scrolling | | | | | | |
| Right-click | | | | | | |
| Pinch to zoom, and dragging | | | | | | |
| Delay between your finger and something happening | | | | | | |

**15. How easy was it to find the controls you needed (the panel, the dock, settings)?**
- [ ] Obvious
- [ ] Found them, took a moment
- [ ] Had to hunt, or never found one I knew should exist

**16. What did you go looking for and fail to find?**

**17. Have you used Observe mode (watching without sending input)? What for, and did it do what you
wanted?**

---

## E. Sound, and staying connected

**18. Sound from the Mac: quality, and whether it lines up with the picture.** (X if you did not
use it)

**19. Did a session ever drop, freeze, or take a long time to come back?** Roughly how often, and
what were you doing at the time?

**20. How did reconnecting feel when it happened?**
- [ ] Automatic, barely noticed
- [ ] It came back, but it was obviously a reconnect
- [ ] I had to redo something, or it did not come back
- [ ] Never happened

**21. If you have switched a sleeping or off Mac on remotely (Wake on LAN), did it work?** (X if you
did not try)

---

## F. Everything past the screen

**22. Which of these have you used?** Tick all that apply, and rate the ones you tick.
- [ ] Terminal / SSH sessions
- [ ] The file browser, uploads and downloads
- [ ] Clipboard between devices
- [ ] Screenshots to Photos
- [ ] Picture in Picture, the widget, or the Live Activity
- [ ] Spaces, drawn as tappable pictures
- [ ] Opening an app on the Mac that was not running
- [ ] Several of the Mac's windows in one picture
- [ ] More than one Mac
- [ ] Macros, snippets or quick commands

**23. Of those, which one was confusing, or did not do what you expected?**

**24. Which one do you actually use, or would use, most weeks?**

---

## G. Plans and money

**25. Did you hit the free limit (one hour of relay time per day)?**
- [ ] Yes
- [ ] No, I stayed under it
- [ ] No, I never used the relay (I was always on my own network)

**26. For what you want to do with this, is an hour a day of away-from-home use enough?** Say what
you would need instead, if not.

**27. Looking at the tiers (free, Relay at $2.99, Relay Plus at $5.99, Pro at $9.99 monthly), which
would you pick for yourself, and why? "None" is a valid, useful answer.**

**28. Is anything gated that you expected to be free? Is there anything you would pay for that is
not offered?**

---

## H. In your own words

**29. Did you give up at any point, even briefly? At what step, and why?**

**30. If you could fix exactly one thing, what is it?**

**31. What surprised you, in either direction?**

**32. Who would you recommend this to, and what would you tell them it is for?**

**33. Anything else. Space for whatever the questions above did not reach.**

---

## Notes for whoever is running this

- Do not explain how a feature works before they try it. Where they get stuck unassisted is the
  measurement.
- Record the Mac model, macOS version and iPhone model from section A even if they skip the rest.
  Most of the faults worth chasing are one of those three.
- Section C's symptom list and section B's permission question map onto known faults; if several
  testers tick the same box, that is the next thing to build, not a coincidence.
- Answers about the relay (sections E and G) are the least useful from anyone on the same network
  as their Mac. Check question 4 before weighing them.
