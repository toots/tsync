// vault §8.1: a vault's mark, its icon or tsync's glyph in its colour. Shared by
// the content script and the extension's pages.
"use strict";

const TsyncMark = (() => {
  const SVG = "http://www.w3.org/2000/svg";
  const GLYPH = ["M9 5 11 3V15a2 2 0 0 0 2 2h2v2h-2a4 4 0 0 1-4-4Z", "M6 7h8v2H6Z", "M15 15.4 19.6 18 15 20.6Z"];

  function element(look, size = 18) {
    if (look && look.icon) {
      const img = document.createElement("img");
      img.src = `data:image/png;base64,${look.icon}`;
      img.width = img.height = size;
      img.alt = "";
      // A page whose policy blocks data: images gets the glyph in the colour instead.
      img.addEventListener("error", () => img.replaceWith(element({ color: look.color }, size)), { once: true });
      return img;
    }
    const svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("width", size);
    svg.setAttribute("height", size);
    svg.setAttribute("aria-hidden", "true");
    // Only a #rrggbb the owner checked reaches here; anything else is tsync's own blue.
    svg.style.color = look && /^#[0-9a-f]{6}$/i.test(look.color) ? look.color : "#2563eb";
    svg.setAttribute("fill", "currentColor");
    for (const d of GLYPH) {
      const path = document.createElementNS(SVG, "path");
      path.setAttribute("d", d);
      svg.appendChild(path);
    }
    return svg;
  }

  // vault §8.1: rows grouped by domain in name order; a page draws a header per group only when
  // there are several, so a picker of one domain draws no mark.
  function byVault(items) {
    const groups = new Map();
    for (const item of items) {
      if (!groups.has(item.domain)) groups.set(item.domain, []);
      groups.get(item.domain).push(item);
    }
    return [...groups].sort(([a], [b]) => a.localeCompare(b)).map(([domain, rows]) => ({ domain, items: rows }));
  }

  return { element, byVault };
})();

if (typeof module !== "undefined") module.exports = TsyncMark;
