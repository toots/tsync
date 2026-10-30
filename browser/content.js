// passwords/browser §3, §4, §5: the content script, in every frame, in the
// extension's isolated world. It finds fields and fills them; it asks the
// service worker only on the user's gesture. What it draws is in a closed
// shadow root the page cannot reach into.
"use strict";

(() => {
  if (window.__tsyncContent) return;
  window.__tsyncContent = true;

  const ICON = chrome.runtime.getURL("icons/field.svg");
  const CLOSED = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'%3E%3Cpath d='M2 3.5 5 6.5 8 3.5' fill='none' stroke='white' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E";
  const OPENED = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'%3E%3Cpath d='M2 6.5 5 3.5 8 6.5' fill='none' stroke='white' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E";
  const kinds = new WeakMap();
  let conditional = null; // a passkey request waiting for a pick (§5)

  // --- the overlay -----------------------------------------------------------

  const host = document.createElement("tsync-overlay");
  const shadow = host.attachShadow({ mode: "closed" });
  shadow.innerHTML = `<style>
    :host { all: initial; }
    .icon { position: fixed; width: 34px; height: 20px; cursor: pointer; z-index: 2147483646; border: 0; padding: 0;
            border-radius: 10px; background: url("${ICON}") left center / 20px no-repeat, url("${CLOSED}") right 4px center / 10px no-repeat, #2563eb; }
    .icon.open { background: url("${ICON}") left center / 20px no-repeat, url("${OPENED}") right 4px center / 10px no-repeat, #2563eb; }
    .icon:hover { box-shadow: 0 0 0 3px #2563eb33; }
    .menu { position: fixed; z-index: 2147483647; min-width: 240px; max-width: 360px;
            background: Canvas; color: CanvasText; border: 1px solid #8884; border-radius: 8px;
            box-shadow: 0 4px 16px #0003; font: 13px system-ui, sans-serif; padding: 4px;
            box-sizing: border-box; overflow-y: auto; overscroll-behavior: contain; }
    .row { display: block; width: 100%; text-align: left; background: none; border: 0; color: inherit;
           padding: 6px 8px; border-radius: 6px; cursor: pointer; font: inherit; }
    .row:hover, .row:focus { background: #8882; }
    .row small { display: block; opacity: .65; margin-left: 24px; }
    .row > svg, .row > img { vertical-align: -3px; margin-right: 8px; }
    .note { padding: 6px 8px; opacity: .7; }
    .heading { font-weight: 600; opacity: .8; padding-bottom: 2px; }
    .heading > svg, .heading > img { vertical-align: -2px; }
  </style><div class="menu" hidden></div>`;
  const menu = shadow.querySelector(".menu");

  // §6: the icons and the menu with nothing painted over them, a decoy that lets
  // clicks through included, as Chrome's IntersectionObserver v2 reports it.
  const tracked = typeof IntersectionObserverEntry !== "undefined" && "isVisible" in IntersectionObserverEntry.prototype;
  const unobscured = new WeakSet();
  const painted = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isVisible) unobscured.add(entry.target);
      else unobscured.delete(entry.target);
    }
  }, { trackVisibility: true, delay: 100 });
  painted.observe(menu);

  // §6: a page's stylesheet cannot fade, hide or reshape the overlay; inline
  // !important wins over it.
  for (const [k, v] of [["opacity", "1"], ["visibility", "visible"], ["filter", "none"], ["clip-path", "none"],
    ["mix-blend-mode", "normal"], ["display", "block"], ["transform", "none"], ["position", "static"]]) {
    host.style.setProperty(k, v, "important");
  }
  const mount = () => document.documentElement.appendChild(host);
  if (document.documentElement) mount();
  else document.addEventListener("DOMContentLoaded", mount, { once: true });

  function placeIcon(el, node) {
    const r = el.getBoundingClientRect();
    node.style.left = `${r.right - 42}px`;
    node.style.top = `${r.top + (r.height - 20) / 2}px`;
  }

  // §3.2: Chrome draws its own autofill dropdown below the field, above anything a
  // page holds, so the menu opens above the field and grows upward; below only
  // when there is more room there. It scrolls when taller than its side's room.
  function placeMenu(el) {
    const r = el.getBoundingClientRect();
    menu.style.maxHeight = "";
    const above = r.top - 6, below = innerHeight - r.bottom - 6;
    const up = menu.offsetHeight <= above || above >= below;
    menu.style.maxHeight = `${Math.max(up ? above : below, 0)}px`;
    menu.style.left = `${Math.max(4, Math.min(r.left, innerWidth - menu.offsetWidth - 4))}px`;
    if (up) {
      menu.style.top = "";
      menu.style.bottom = `${innerHeight - r.top + 2}px`;
    } else {
      menu.style.bottom = "";
      menu.style.top = `${r.bottom + 2}px`;
    }
  }

  // --- finding fields (§3.1): asks nothing --------------------------------------

  function describe(input) {
    const label = input.labels && input.labels[0] ? input.labels[0].textContent : input.getAttribute("aria-label");
    const style = getComputedStyle(input);
    return {
      type: input.type, name: input.name, id: input.id, label, placeholder: input.placeholder,
      autocomplete: input.getAttribute("autocomplete"),
      hidden: input.type === "hidden" || style.display === "none" || style.visibility === "hidden" || input.offsetWidth === 0,
      disabled: input.disabled, readOnly: input.readOnly,
      ignored: input.hasAttribute("data-1p-ignore") || input.hasAttribute("data-bwignore") || input.getAttribute("data-lpignore") === "true",
    };
  }

  // passwords §5.1: the fields that offer a suggested password.
  const newPassword = new WeakSet();

  function scan() {
    const groups = new Map();
    for (const input of document.querySelectorAll("input")) {
      const key = input.form || document;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(input);
    }
    for (const inputs of groups.values()) {
      const described = inputs.map(describe);
      const found = TsyncFields.classify(described);
      const fresh = TsyncFields.newPasswords(described, found);
      inputs.forEach((input, i) => {
        if (found[i]) kinds.set(input, found[i]);
        else kinds.delete(input);
        if (fresh[i]) newPassword.add(input);
        else newPassword.delete(input);
      });
    }
    mark();
  }

  // §3.1: every field found carries its icon from the start, as long as it is drawn.
  const badges = new Map();

  function badge(el) {
    const b = document.createElement("button");
    b.className = "icon";
    b.title = "tsync";
    b.addEventListener("mousedown", (e) => e.preventDefault());
    b.setAttribute("aria-expanded", "false");
    b.addEventListener("click", (e) => seen(e) && (openFor === el ? close() : open(el)));
    shadow.insertBefore(b, menu);
    painted.observe(b);
    return b;
  }

  function mark() {
    for (const [el, b] of badges) {
      if (!kinds.has(el) || !el.isConnected) {
        painted.unobserve(b);
        b.remove();
        badges.delete(el);
      }
    }
    for (const el of document.querySelectorAll("input")) {
      if (kinds.has(el) && !badges.has(el)) badges.set(el, badge(el));
    }
    follow();
  }

  // Pages hide a field they keep for later steps by opacity, an ancestor's visibility or clip, or aria-hidden.
  function drawn(el, r) {
    if (!el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
    if (el.closest("[aria-hidden=true], [inert]")) return false;
    for (let n = el.parentElement; n && n !== document.body; n = n.parentElement) {
      if (getComputedStyle(n).overflow === "visible") continue;
      const c = n.getBoundingClientRect();
      if (r.bottom <= c.top || r.top >= c.bottom || r.right <= c.left || r.left >= c.right) return false;
    }
    return true;
  }

  function follow() {
    for (const [el, b] of badges) {
      const r = el.getBoundingClientRect();
      b.hidden = r.width < 48 || r.height < 16 || r.bottom < 0 || r.top > innerHeight || !drawn(el, r);
      if (!b.hidden) placeIcon(el, b);
    }
  }

  let following = 0;
  const refollow = () => {
    if (!following) following = requestAnimationFrame(() => { following = 0; follow(); });
  };

  let scanning = null;
  const rescan = () => {
    clearTimeout(scanning);
    scanning = setTimeout(scan, 300);
  };
  new MutationObserver(rescan).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ["type", "autocomplete", "hidden", "style", "class"] });
  scan();

  window.addEventListener("scroll", () => { close(); refollow(); }, true);
  window.addEventListener("resize", refollow);
  document.addEventListener("transitionend", refollow, true);
  document.addEventListener("focusin", refollow, true);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); }, true);
  // Clicks inside the overlay reach the page retargeted to its host.
  document.addEventListener("mousedown", (e) => { if (e.target !== host && e.target !== openFor) close(); }, true);

  // --- filling (§3.2): on a gesture only -------------------------------------

  // §6: a pick counts only for a real click on the overlay as the user sees it:
  // trusted, on top at the click's point, unobscured, with nothing in the top layer over it.
  function seen(e) {
    if (!e.isTrusted) return false;
    if (document.elementFromPoint(e.clientX, e.clientY) !== host) return false;
    if (tracked && !unobscured.has(e.currentTarget.closest(".menu") || e.currentTarget)) return false;
    const style = getComputedStyle(host);
    if (style.opacity !== "1" || style.visibility !== "visible" || style.filter !== "none") return false;
    try {
      if (document.querySelector(":modal, :popover-open")) return false;
    } catch (_) {}
    return true;
  }


  function row(title, detail, action, look) {
    const b = document.createElement("button");
    b.className = "row";
    if (look !== undefined) b.appendChild(TsyncMark.element(look, 16));
    b.appendChild(document.createTextNode(title));
    if (detail) {
      const small = document.createElement("small");
      small.textContent = detail;
      b.appendChild(small);
    }
    b.addEventListener("mousedown", (e) => e.preventDefault());
    b.addEventListener("click", (e) => seen(e) && action());
    return b;
  }
  function header(domain, look) {
    const d = document.createElement("div");
    d.className = "note heading";
    d.append(TsyncMark.element(look, 14), document.createTextNode(` ${domain}`));
    return d;
  }
  function note(text) {
    const d = document.createElement("div");
    d.className = "note";
    d.textContent = text;
    return d;
  }

  // The field whose menu is open, its badge showing the open state.
  let openFor = null;
  function showOpen(el, opened) {
    const b = badges.get(el);
    if (!b) return;
    b.classList.toggle("open", opened);
    b.setAttribute("aria-expanded", String(opened));
  }
  function close() {
    menu.hidden = true;
    if (openFor) showOpen(openFor, false);
    openFor = null;
  }

  async function open(el) {
    const kind = kinds.get(el);
    close();
    openFor = el;
    showOpen(el, true);
    menu.replaceChildren(note("…"));
    menu.hidden = false;
    placeMenu(el);
    let answer;
    try {
      answer = await chrome.runtime.sendMessage({ type: "match", kind });
    } catch (_) {
      answer = { error: "tsync did not answer" };
    }
    if (openFor !== el) return;
    menu.replaceChildren();
    if (newPassword.has(el)) menu.appendChild(row("Use a strong password", "saved in tsync as you pick it", () => suggest(el)));
    if (answer.error) menu.appendChild(note(answer.error));
    const groups = TsyncMark.byVault(answer.logins || []);
    for (const group of groups) {
      if (groups.length > 1) menu.appendChild(header(group.domain, (answer.looks || {})[group.domain] || null));
      for (const login of group.items) {
        const detail = kind === "code" ? [login.username, "one-time code"].filter(Boolean).join(" · ") : login.username;
        menu.appendChild(row(login.title, login.exact ? detail : `${detail} · saved for another site of this domain`, () => pick(el, login, kind)));
      }
    }
    if (conditional && kind !== "code") menu.appendChild(row("Sign in with a passkey", "from tsync", usePasskey));
    for (const domain of answer.locked || []) menu.appendChild(note(`${domain}: tsync is locked — unlock it in tsync`));
    if (!menu.children.length) menu.appendChild(note("Nothing in tsync for this site"));
    placeMenu(el);
  }

  function usernameOf(scope) {
    const inputs = [...scope.querySelectorAll("input")];
    const found = inputs.filter((input) => kinds.get(input) === "username" && input.value).pop();
    if (found) return found.value;
    const kept = inputs.find((input) => !kinds.has(input) && input.value && TsyncFields.keptUsername(describe(input)));
    return kept ? kept.value : "";
  }

  // §5.1: every password field of the form gets the suggestion, its confirmation
  // included; the form remembers the login it went to, for its submit.
  const suggested = new WeakMap();
  async function suggest(el) {
    close();
    const scope = el.form || document;
    const username = usernameOf(scope);
    let answer;
    try {
      answer = await chrome.runtime.sendMessage({ type: "suggest", username });
    } catch (_) {
      return;
    }
    if (!answer || answer.error || !answer.password) return;
    for (const input of scope.querySelectorAll("input")) if (newPassword.has(input)) set(input, answer.password);
    suggested.set(scope, { id: answer.id, domain: answer.domain });
  }

  async function pick(el, login, kind) {
    close();
    let values;
    try {
      values = await chrome.runtime.sendMessage({ type: "fill", domain: login.domain, id: login.id,
        title: login.title, username: login.username, kind });
    } catch (_) {
      return;
    }
    if (!values || values.error) return;
    apply(values, el);
  }

  // Set a value as typing would, so the page's own listeners see it.
  function set(el, value) {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  // The values of one pick, each into its own kind of field: a login's username
  // and password, or a code (§3.2).
  function apply(values, near) {
    const scope = (near && near.form) || document;
    for (const input of scope.querySelectorAll("input")) {
      const kind = kinds.get(input);
      if (kind === "username" && values.username !== undefined && values.username !== "") set(input, values.username);
      else if (kind === "password" && values.password) set(input, values.password);
      else if (kind === "code" && values.code) set(input, values.code);
    }
  }

  chrome.runtime.onMessage.addListener((message, _sender, reply) => {
    if (message.type === "open-menu") {
      const el = document.activeElement;
      if (el instanceof HTMLInputElement && kinds.has(el)) open(el);
    } else if (message.type === "apply" && message.origin === location.origin) {
      // §3.2: the popup's fill lands only in the document it was asked for.
      apply(message.values, document.activeElement instanceof HTMLInputElement ? document.activeElement : null);
    }
    reply({});
  });

  // --- saving (§4) -----------------------------------------------------------

  // §4: offered only for a password the user typed or the browser filled, on the user's own submit;
  // a page can set neither a trusted input event nor the :autofill state.
  const typed = new WeakSet();
  document.addEventListener("input", (e) => {
    if (e.isTrusted && e.target instanceof HTMLInputElement && kinds.get(e.target) === "password") typed.add(e.target);
  }, true);
  // The last pick or password offered: a click that was no submit must not stop the real one's offer.
  let offered = null;
  function offer(form) {
    const scope = form || document;
    const username = usernameOf(scope);
    // §5.1: no sheet; the password itself is not sent again.
    const pick = suggested.get(scope);
    if (pick) {
      if (offered === pick) return;
      offered = pick;
      chrome.runtime.sendMessage({ type: "save-suggested", id: pick.id, domain: pick.domain, username }).catch(() => {});
      return;
    }
    let password = "";
    for (const input of scope.querySelectorAll("input")) {
      if (kinds.get(input) === "password" && input.value && (typed.has(input) || input.matches(":autofill"))) password = input.value;
    }
    if (!password || offered === password) return;
    offered = password;
    chrome.runtime.sendMessage({ type: "offer-save", username, password }).catch(() => {});
  }
  document.addEventListener("submit", (e) => e.isTrusted && offer(e.target), true);
  document.addEventListener("click", (e) => {
    if (!e.isTrusted) return;
    const button = e.target instanceof Element && e.target.closest("button, input[type=submit]");
    if (!button || button.type === "reset") return;
    if (button.form && button.type === "submit") return offer(button.form);
    const names = [button.textContent, button.getAttribute("aria-label"), button.id, button.name];
    if (TsyncFields.submits(names)) offer(button.form);
  }, true);
  // A page that signs in by script has no form to submit: Enter in its password field is the submit.
  document.addEventListener("keydown", (e) => {
    if (e.isTrusted && e.key === "Enter" && kinds.get(e.target) === "password") offer(e.target.form);
  }, true);

  // --- passkeys (§5) ---------------------------------------------------------

  const unreachable = { name: "NotAllowedError", message: "tsync did not answer: reload the page" };
  const answerPage = (id, body) => window.postMessage({ tsync: "webauthn-reply", id, ...body }, window.location.origin);

  window.addEventListener("message", async (event) => {
    const m = event.data;
    if (event.source !== window || !m || m.tsync !== "webauthn") return;
    // §5: tsync out of reach is said to the page; only the user's choice in a sheet hands a
    // request to the browser.
    const ask = (message) => chrome.runtime.sendMessage(message).catch(() => ({ error: unreachable }));
    if (m.kind === "get" && m.mediation === "conditional") {
      const held = await chrome.runtime.sendMessage({ type: "passkey-conditional", publicKey: m.publicKey }).catch(() => ({}));
      if (held.hold) conditional = { id: m.id, publicKey: m.publicKey };
      return;
    }
    answerPage(m.id, await ask({ type: "webauthn", kind: m.kind, publicKey: m.publicKey }));
  });

  // §5: the pick itself is in the extension's sheet, like a modal request's.
  async function usePasskey() {
    close();
    const request = conditional;
    conditional = null;
    const reply = await chrome.runtime.sendMessage({ type: "webauthn", kind: "get", publicKey: request.publicKey }).catch(() => ({ error: unreachable }));
    answerPage(request.id, reply);
  }
})();
