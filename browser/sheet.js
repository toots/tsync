// passwords/browser §4, §5: the extension's own sheet. It shows what the service
// worker asks, and answers only on the user's click.
"use strict";

const token = location.hash.slice(1);
// Keeps the service worker alive while the user decides.
const keepAlive = chrome.runtime.connect({ name: "sheet" });
setInterval(() => keepAlive.postMessage("ping"), 20000);
const main = document.getElementById("sheet");
const answer = (body) => chrome.runtime.sendMessage({ type: "sheet-answer", token, answer: body }).then(() => window.close());

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  Object.assign(node, attrs);
  node.append(...children);
  return node;
}
const button = (label, action, primary) => el("button", { textContent: label, className: primary ? "primary" : "", onclick: action });

function render(item) {
  if (!item) return main.append(el("p", { textContent: "This request is over." }));
  const actions = el("div", { className: "actions" });
  // Every sheet names the origin the browser gave, never a name a page chose.
  const site = item.origin ? new URL(item.origin).host : "";
  switch (item.kind) {
    case "save":
    case "update":
      main.append(
        el("h1", { textContent: item.kind === "save" ? `Save this login in tsync?` : `Update the password for ${item.title}?` }),
        el("p", { textContent: site }), el("p", { className: "detail", textContent: item.username || "(no username)" }),
      );
      if (item.kind === "save" && !item.incognito) actions.append(button("Never for this site", () => answer({ action: "never" })));
      actions.append(button("Not now", () => answer({ action: "cancel" })), button(item.kind === "save" ? "Save" : "Update", () => answer({ action: "ok" }), true));
      break;
    case "save-locked":
      main.append(el("h1", { textContent: "This login was not saved" }),
        el("p", { className: "detail", textContent: `tsync is locked. Unlock it in tsync, then sign in to ${site} again to save it.` }));
      actions.append(button("OK", () => answer({ action: "cancel" }), true));
      break;
    case "locked":
      main.append(el("h1", { textContent: `tsync is locked` }),
        el("p", { className: "detail", textContent: `Unlock ${item.domains.join(", ")} in tsync to use your passkeys on ${site}.` }));
      actions.append(button("Use another passkey or device", () => answer({ action: "fallback" })), button("Cancel", () => answer({ action: "cancel" }), true));
      break;
    case "fill-suffix":
      main.append(el("h1", { textContent: `Fill ${item.title} on ${site}?` }),
        el("p", { className: "detail", textContent: `${item.username || "This login"} is saved for another site of this domain, not for ${site} itself.` }));
      actions.append(button("Cancel", () => answer({ action: "cancel" })), button("Fill", () => answer({ action: "ok" }), true));
      break;
    case "passkey-get":
      main.append(el("h1", { textContent: `Sign in to ${site} with a passkey` }));
      for (const key of item.passkeys) {
        const look = (item.looks || {})[key.domain] || null;
        main.append(el("button", { className: "row mark", onclick: () => answer({ action: "pick", id: key.id }) },
          TsyncMark.element(look, 20),
          el("span", {}, el("strong", { textContent: key.userDisplayName || key.userName }), el("small", { textContent: key.userName }))));
      }
      actions.append(button("Use another passkey or device", () => answer({ action: "fallback" })));
      break;
    case "passkey-create":
      main.append(el("h1", { textContent: `Save a passkey for ${item.user} on ${site} in tsync?` }));
      actions.append(button("Use another passkey or device", () => answer({ action: "fallback" })), button("Save", () => answer({ action: "ok" }), true));
      break;
    case "passphrase": {
      // §5, Linux: verifies the user; it unlocks nothing and is never kept.
      const field = el("input", { type: "password", autocomplete: "off", placeholder: "Vault passphrase" });
      const show = el("input", { type: "checkbox", onchange: () => (field.type = show.checked ? "text" : "password") });
      main.append(
        el("h1", { textContent: `Verify it's you for ${site}` }),
        el("p", { className: "detail", textContent: "Your tsync vault passphrase confirms this passkey request. It unlocks nothing." }),
        field, el("label", {}, show, " Show"),
      );
      const send = () => answer({ action: "ok", passphrase: field.value });
      field.addEventListener("keydown", (e) => e.key === "Enter" && send());
      actions.append(button("Cancel", () => answer({ action: "cancel" })), button("Verify", send, true));
      setTimeout(() => field.focus(), 0);
      break;
    }
  }
  main.append(actions);
}

chrome.runtime.sendMessage({ type: "sheet-item", token }).then(render);
document.addEventListener("keydown", (e) => e.key === "Escape" && answer({ action: "cancel" }));
