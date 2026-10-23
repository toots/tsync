// passwords/browser §3, §4, §5: the content script, in every frame, in the
// extension's isolated world. It finds fields and fills them; it asks the
// service worker only on the user's gesture. What it draws is in a closed
// shadow root the page cannot reach into.
"use strict";

(() => {
  if (window.__tsyncContent) return;
  window.__tsyncContent = true;

  const ICON = chrome.runtime.getURL("icons/field.svg");
  const kinds = new WeakMap();
  let conditional = null; // a passkey request waiting for a pick (§5)

  // --- the overlay -----------------------------------------------------------

  const host = document.createElement("tsync-overlay");
  const shadow = host.attachShadow({ mode: "closed" });
  shadow.innerHTML = `<style>
    :host { all: initial; }
    .icon { position: fixed; width: 20px; height: 20px; cursor: pointer; z-index: 2147483646;
            background: url("${ICON}") center / 20px no-repeat; border: 0; padding: 0; border-radius: 50%;
            opacity: .9; }
    .icon:hover { opacity: 1; box-shadow: 0 0 0 3px #2563eb33; }
    .menu { position: fixed; z-index: 2147483647; min-width: 240px; max-width: 360px;
            background: Canvas; color: CanvasText; border: 1px solid #8884; border-radius: 8px;
            box-shadow: 0 4px 16px #0003; font: 13px system-ui, sans-serif; padding: 4px; }
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

  // §6: a page's stylesheet cannot fade, hide or reshape the overlay; inline
  // !important wins over it.
  for (const [k, v] of [["opacity", "1"], ["visibility", "visible"], ["filter", "none"], ["clip-path", "none"],
    ["mix-blend-mode", "normal"], ["display", "block"], ["transform", "none"], ["position", "static"]]) {
    host.style.setProperty(k, v, "important");
  }
  const mount = () => document.documentElement.appendChild(host);
  if (document.documentElement) mount();
  else document.addEventListener("DOMContentLoaded", mount, { once: true });

  function place(el, node, below) {
    const r = el.getBoundingClientRect();
    if (below) {
      node.style.left = `${r.left}px`;
      node.style.top = `${r.bottom + 2}px`;
    } else {
      node.style.left = `${r.right - 28}px`;
      node.style.top = `${r.top + (r.height - 20) / 2}px`;
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
    b.addEventListener("click", (e) => seen(e) && open(el));
    shadow.insertBefore(b, menu);
    return b;
  }

  function mark() {
    for (const [el, b] of badges) {
      if (!kinds.has(el) || !el.isConnected) {
        b.remove();
        badges.delete(el);
      }
    }
    for (const el of document.querySelectorAll("input")) {
      if (kinds.has(el) && !badges.has(el)) badges.set(el, badge(el));
    }
    follow();
  }

  // ponytail: a field clipped by a scrolled container keeps its icon over the clip; hide by intersection if pages show it.
  function follow() {
    for (const [el, b] of badges) {
      const r = el.getBoundingClientRect();
      b.hidden = r.width < 48 || r.height < 16 || r.bottom < 0 || r.top > innerHeight;
      if (!b.hidden) place(el, b, false);
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

  window.addEventListener("scroll", () => { menu.hidden = true; refollow(); }, true);
  window.addEventListener("resize", refollow);
  document.addEventListener("focusin", refollow, true);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") menu.hidden = true; }, true);

  // --- filling (§3.2): on a gesture only -------------------------------------

  // §6: a pick counts only for a real click on the overlay as the user sees it:
  // trusted, on top at the click's point, with nothing in the top layer over it.
  function seen(e) {
    if (!e.isTrusted) return false;
    if (document.elementFromPoint(e.clientX, e.clientY) !== host) return false;
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

  async function open(el) {
    const kind = kinds.get(el);
    menu.replaceChildren(note("…"));
    place(el, menu, true);
    menu.hidden = false;
    let answer;
    try {
      answer = await chrome.runtime.sendMessage({ type: "match", kind });
    } catch (_) {
      answer = { error: "tsync did not answer" };
    }
    menu.replaceChildren();
    if (newPassword.has(el)) menu.appendChild(row("Use a strong password", "saved in tsync as you pick it", () => suggest(el)));
    if (answer.error) menu.appendChild(note(answer.error));
    // vault §8.1: with several domains, each one's logins under a header carrying its mark.
    let heading = null;
    const order = [...new Set((answer.logins || []).map((l) => l.domain))];
    const grouped = [...(answer.logins || [])].sort((a, b) => order.indexOf(a.domain) - order.indexOf(b.domain));
    for (const login of grouped) {
      if (answer.domains > 1 && login.domain !== heading) {
        heading = login.domain;
        menu.appendChild(header(login.domain, (answer.looks || {})[login.domain] || null));
      }
      const detail = kind === "code" ? "one-time code" : login.username;
      menu.appendChild(row(login.title, login.exact ? detail : `${detail} · saved for another site of this domain`, () => pick(el, login, kind)));
    }
    if (conditional && kind !== "code") menu.appendChild(row("Sign in with a passkey", "from tsync", usePasskey));
    for (const domain of answer.locked || []) menu.appendChild(note(`${domain}: tsync is locked — unlock it in tsync`));
    if (!menu.children.length) menu.appendChild(note("Nothing in tsync for this site"));
  }

  // §5.1: every password field of the form gets the suggestion, its confirmation
  // included; the form remembers the login it went to, for its submit.
  const suggested = new WeakMap();
  async function suggest(el) {
    menu.hidden = true;
    const scope = el.form || document;
    let username = "";
    for (const input of scope.querySelectorAll("input")) if (kinds.get(input) === "username" && input.value) username = input.value;
    let answer;
    try {
      answer = await chrome.runtime.sendMessage({ type: "suggest", username });
    } catch (_) {
      return;
    }
    if (!answer || answer.error || !answer.password) return;
    for (const input of scope.querySelectorAll("input")) if (kinds.get(input) === "password") set(input, answer.password);
    suggested.set(scope, { id: answer.id, domain: answer.domain });
  }

  async function pick(el, login, kind) {
    menu.hidden = true;
    let values;
    try {
      values = await chrome.runtime.sendMessage({ type: "fill", domain: login.domain, id: login.id, exact: login.exact,
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

  // §4: offered only for a password the user typed, on the user's own submit.
  const typed = new WeakSet();
  document.addEventListener("input", (e) => {
    if (e.isTrusted && e.target instanceof HTMLInputElement && kinds.get(e.target) === "password") typed.add(e.target);
  }, true);
  let offered = false;
  function offer(form) {
    if (offered) return;
    const scope = form || document;
    // §5.1: no sheet; the password itself is not sent again.
    const pick = suggested.get(scope);
    if (pick) {
      offered = true;
      let username = "";
      for (const input of scope.querySelectorAll("input")) if (kinds.get(input) === "username" && input.value) username = input.value;
      chrome.runtime.sendMessage({ type: "save-suggested", id: pick.id, domain: pick.domain, username }).catch(() => {});
      return;
    }
    let username = "", password = "";
    for (const input of scope.querySelectorAll("input")) {
      const kind = kinds.get(input);
      if (kind === "username" && input.value) username = input.value;
      if (kind === "password" && input.value && typed.has(input)) password = input.value;
    }
    if (!password) return;
    offered = true;
    chrome.runtime.sendMessage({ type: "offer-save", username, password }).catch(() => {});
  }
  document.addEventListener("submit", (e) => e.isTrusted && offer(e.target), true);
  document.addEventListener("click", (e) => {
    if (!e.isTrusted) return;
    const button = e.target instanceof Element && e.target.closest("button, input[type=submit]");
    if (button && (button.type === "submit" || button.form)) offer(button.form);
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
    menu.hidden = true;
    const request = conditional;
    conditional = null;
    const reply = await chrome.runtime.sendMessage({ type: "webauthn", kind: "get", publicKey: request.publicKey }).catch(() => ({ error: unreachable }));
    answerPage(request.id, reply);
  }
})();
