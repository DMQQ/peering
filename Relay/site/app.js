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
    menu.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      menu.setAttribute("aria-expanded", open ? "true" : "false");
    });

    // Tapping a link is a request to go somewhere, and the menu it was tapped in is not that
    // place. Closing it here rather than on scroll means a link that lands mid-page does not
    // leave a panel open over the section it just moved to.
    nav.addEventListener("click", function (event) {
      if (event.target.tagName === "A") {
        nav.classList.remove("open");
        menu.setAttribute("aria-expanded", "false");
      }
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
