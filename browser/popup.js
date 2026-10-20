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
  for (const d of domains) {
    main.append(el("p", { className: "detail", textContent: `${d.domain}: ${d.state === "unlocked" ? "unlocked" : d.state === "locked" ? "locked — unlock it in tsync" : d.state}` }));
  }
  if (!state.origin) return main.append(el("p", { className: "detail", textContent: "Not a web page." }));
  main.append(el("h2", { textContent: new URL(state.origin).host }));
  const logins = (state.match && state.match.ok && state.match.logins) || [];
  if (!logins.length) main.append(el("p", { className: "detail", textContent: "Nothing in tsync for this site." }));
  for (const login of logins) {
    const fill = el("button", { textContent: "Fill", className: "primary", onclick: async () => {
      await chrome.runtime.sendMessage({ type: "popup-fill", tabId: tab.id, domain: login.domain, id: login.id });
      window.close();
    } });
    const actions = el("div", { className: "actions" }, fill);
    if (login.code) {
      actions.prepend(el("button", { textContent: "Copy code", onclick: async () => {
        const reply = await chrome.runtime.sendMessage({ type: "popup-fill", tabId: tab.id, domain: login.domain, id: login.id, copyCode: true });
        if (reply.code) await navigator.clipboard.writeText(reply.code);
        main.append(el("p", { className: "detail", textContent: "Code copied. It stays on the clipboard until replaced." }));
      } }));
    }
    main.append(el("div", { className: "login" }, el("strong", { textContent: login.title }), el("small", { textContent: login.username }), actions));
  }
}

render();
