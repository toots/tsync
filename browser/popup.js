// passwords/browser §3.3: the current tab's logins, each domain's state, and what
// is missing. No other site's logins, no password.
"use strict";

const main = document.getElementById("popup");
function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  Object.assign(node, attrs);
  node.append(...children);
  return node;
}

async function render() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const state = await chrome.runtime.sendMessage({ type: "popup-state", tabId: tab.id });
  main.replaceChildren(el("h1", { textContent: "tsync" }));
  if (!state.status || !state.status.ok) {
    main.append(el("p", { className: "detail", textContent: state.status ? state.status.error : "tsync did not answer" }));
    return;
  }
  const domains = state.status.domains || [];
  if (!domains.length) main.append(el("p", { className: "detail", textContent: "No domain uses passwords on this machine." }));
  const looks = {};
  for (const d of domains) {
    looks[d.domain] = d.appearance || null;
    main.append(el("p", { className: "detail mark" }, TsyncMark.element(d.appearance, 16),
      ` ${d.domain}: ${d.state === "unlocked" ? "unlocked" : d.state === "locked" ? "locked — unlock it in tsync" : d.state}`));
  }
  // §3.3: off from the extension's install; turning them back on is the user's choice.
  const services = chrome.privacy?.services || {};
  const browserOwn = ["passwordSavingEnabled", "autofillAddressEnabled", "autofillCreditCardEnabled"]
    .map((name) => services[name]).filter(Boolean);
  const settings = await Promise.all(browserOwn.map((s) => s.get({})));
  const ours = (s) => s.levelOfControl === "controllable_by_this_extension" || s.levelOfControl === "controlled_by_this_extension";
  const controllable = browserOwn.filter((_, i) => ours(settings[i]));
  if (controllable.length) {
    const box = el("input", { type: "checkbox", checked: settings.filter(ours).every((s) => s.value === false), onchange: () =>
      controllable.forEach((s) => (box.checked ? s.set({ value: false }) : s.clear({}))) });
    main.append(el("label", { className: "detail" }, box, " Turn off the browser's own password saving and autofill"),
      el("p", { className: "detail", textContent: "Passwords the browser already saved still fill from its own list: remove them in its password manager." }));
  }
  if (!state.origin) return main.append(el("p", { className: "detail", textContent: "Not a web page." }));
  main.append(el("h2", { textContent: new URL(state.origin).host }));
  const logins = (state.match && state.match.ok && state.match.logins) || [];
  if (!logins.length) main.append(el("p", { className: "detail", textContent: "Nothing in tsync for this site." }));
  const groups = TsyncMark.byVault(logins);
  for (const group of groups) {
    if (groups.length > 1) main.append(el("p", { className: "detail mark" }, TsyncMark.element(looks[group.domain], 16), ` ${group.domain}`));
    for (const login of group.items) main.append(loginRow(tab, login));
  }
}

function loginRow(tab, login) {
  const fill = el("button", { textContent: "Fill", className: "primary", onclick: async () => {
    const reply = await chrome.runtime.sendMessage({ type: "popup-fill", tabId: tab.id, domain: login.domain, id: login.id,
      title: login.title, username: login.username });
    if (reply && reply.error) main.append(el("p", { className: "detail", textContent: reply.error }));
    else window.close();
  } });
  const actions = el("div", { className: "actions" }, fill);
  if (login.code) {
    actions.prepend(el("button", { textContent: "Copy code", onclick: async () => {
      const reply = await chrome.runtime.sendMessage({ type: "popup-fill", tabId: tab.id, domain: login.domain, id: login.id,
        title: login.title, username: login.username, kind: "code" });
      if (!reply || !reply.code) return main.append(el("p", { className: "detail", textContent: (reply && reply.error) || "tsync gave no code." }));
      await navigator.clipboard.writeText(reply.code);
      main.append(el("p", { className: "detail", textContent: "Code copied. It stays on the clipboard until replaced." }));
    } }));
  }
  return el("div", { className: "login" },
    el("strong", { textContent: login.title }),
    el("small", { textContent: login.username }), actions);
}

render();
