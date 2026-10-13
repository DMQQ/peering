/* Peering — the site's behaviour.
 *
 * Three small things and nothing else: the menu on a narrow screen, the hairline that appears
 * under the bar once the page has moved, and the arrival of each section. All of it is optional —
 * the page reads and works with this file missing, which is the only condition under which a
 * script belongs on a page whose job is to be read.
 */

(function () {
  "use strict";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* The bar's hairline. There is no border until the page has moved, so the top of the document
     does not have a line across it that means nothing yet. */
  var bar = document.getElementById("bar");
  function onScroll() {
    if (bar) bar.classList.toggle("scrolled", window.scrollY > 8);
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* The menu, on screens too narrow for the links to fit. */
  var menu = document.getElementById("menu");
  var nav = document.getElementById("nav");
  if (menu && nav) {
    function setMenu(open) {
      nav.classList.toggle("open", open);
      if (bar) bar.classList.toggle("menu-open", open);
      menu.setAttribute("aria-expanded", open ? "true" : "false");
    }

    menu.addEventListener("click", function () {
      setMenu(!nav.classList.contains("open"));
    });

    // Tapping a link is a request to go somewhere, and the menu it was tapped in is not that
    // place. Closing it here rather than on scroll means a link that lands mid-page does not
    // leave a panel open over the section it just moved to.
    nav.addEventListener("click", function (event) {
      if (event.target.tagName === "A") setMenu(false);
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && nav.classList.contains("open")) {
        setMenu(false);
        menu.focus();
      }
    });
  }

  /* The shine that runs round a card's edge while it is under the pointer.

     The stylesheet can turn it, but it cannot decide the two things that make it read as light
     rather than as a decoration switching on, and both of them are questions only this file can
     answer.

     **Where it starts.** A card's shine used to begin at the top of the ring every time, because
     `0deg` is where a conic gradient begins and nothing knew any better. It begins at the point on
     the edge the pointer crossed instead, which is where a reader who has just moved onto the card
     is already looking: the light comes out from under the cursor and travels on from there.

     **When it stops.** On the way out, the sweep in flight finishes. Cutting it the moment the
     pointer leaves is what makes it a hover state rather than an event, and the cut is the more
     obvious of the two because the wedge is halfway round an edge at the time. So the turn ends at
     the end of a lap: the animation is `infinite` and this file ends it on an iteration boundary,
     where the wedge is back where it started and stopping is not a jump. */
  if (!reduced) {
    document.querySelectorAll(".card").forEach(function (card) {
      card.addEventListener("pointerenter", function (event) {
        var box = card.getBoundingClientRect();
        /* The gradient's own origin, which is twelve o'clock going clockwise, so the angle is
           measured from straight up rather than from the x axis, and `atan2` takes its arguments
           in the order that means. */
        var crossed = Math.atan2(
          event.clientX - (box.left + box.width / 2),
          box.top + box.height / 2 - event.clientY
        ) / (Math.PI * 2);

        /* Backed off by the length of the gradient's own tail, so the bright leading edge of the
           wedge lands under the cursor rather than the transparent four tenths behind it. */
        card.style.setProperty("--shine", (((crossed - 0.995) % 1) + 1) % 1 + "turn");

        /* A second entry while a turn is still in flight starts a new one from the new edge. The
           class has to come off and the style be read again in between, or the re-add is the same
           animation carrying on rather than a new one, which is why the width is asked for, and
           why it is only asked for in this case. */
        if (card.classList.contains("is-shining")) {
          card.classList.remove("is-shining");
          void card.offsetWidth;
        }
        card.classList.add("is-shining", "is-lit");
      });

      /* Only the light goes out here, and only when there is nothing left to finish. A sweep still
         running keeps the card lit until its lap is done. */
      card.addEventListener("pointerleave", function () {
        if (!card.classList.contains("is-shining")) card.classList.remove("is-lit");
      });

      card.addEventListener("animationiteration", function (event) {
        if (event.target !== card || event.pseudoElement !== "::after") return;
        if (card.matches(":hover")) return;
        card.classList.remove("is-shining", "is-lit");
      });
    });
  }

  /* Each section rising as it is reached. Staggered within a section so a row of cards arrives
     in the order it is read rather than all at once, which is the same reason the app's own
     screens stagger. */
  var targets = document.querySelectorAll(".section h2, .section-lede, .card, .faq details");

  targets.forEach(function (node, index) {
    node.classList.add("reveal");
    // The stagger is per row, not per page: the index within the section it belongs to, so a
    // section eight rows down the page does not wait two seconds to begin.
    var siblings = node.parentElement ? node.parentElement.children : [];
    var position = Array.prototype.indexOf.call(siblings, node);
    node.style.transitionDelay = Math.min(position, 5) * 0.06 + "s";
  });

  if (reduced || !("IntersectionObserver" in window)) {
    targets.forEach(function (node) { node.classList.add("in"); });
    return;
  }

  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("in");
      observer.unobserve(entry.target);
    });
  }, { rootMargin: "0px 0px -4% 0px", threshold: 0.04 });

  targets.forEach(function (node) { observer.observe(node); });

  /* Which section the reader is in, marked in the bar. */
  var links = Array.prototype.slice.call(document.querySelectorAll(".nav a[href^='#']"));
  var sections = links
    .map(function (link) { return document.querySelector(link.getAttribute("href")); })
    .filter(Boolean);

  if (!sections.length) return;

  var spy = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      links.forEach(function (link) {
        var current = link.getAttribute("href") === "#" + entry.target.id;
        if (current) link.setAttribute("aria-current", "true");
        else link.removeAttribute("aria-current");
      });
    });
  }, { rootMargin: "-45% 0px -50% 0px" });

  sections.forEach(function (section) { spy.observe(section); });
})();
