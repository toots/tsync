// passwords/browser §4, §5: the extension's own sheet. It shows what the service
// worker asks, and answers only on the user's click.
"use strict";

const token = location.hash.slice(1);
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
  switch (item.kind) {
    case "save":
    case "update":
      main.append(
        el("h1", { textContent: item.kind === "save" ? `Save this login in tsync?` : `Update the password for ${item.title}?` }),
        el("p", { textContent: item.site }), el("p", { className: "detail", textContent: item.username || "(no username)" }),
      );
      if (item.kind === "save") actions.append(button("Never for this site", () => answer({ action: "never" })));
      actions.append(button("Not now", () => answer({ action: "cancel" })), button(item.kind === "save" ? "Save" : "Update", () => answer({ action: "ok" }), true));
      break;
    case "passkey-get":
      main.append(el("h1", { textContent: `Sign in to ${item.site} with a passkey` }));
      for (const key of item.passkeys) {
        main.append(el("button", { className: "row", onclick: () => answer({ action: "pick", id: key.id }) },
          el("strong", { textContent: key.userDisplayName || key.userName }), el("small", { textContent: key.userName })));
      }
      actions.append(button("Use another passkey or device", () => answer({ action: "fallback" })));
      break;
    case "passkey-create":
      main.append(el("h1", { textContent: `Save a passkey for ${item.user} on ${item.site} in tsync?` }));
      actions.append(button("Use another passkey or device", () => answer({ action: "fallback" })), button("Save", () => answer({ action: "ok" }), true));
      break;
    case "passphrase": {
      // §5, Linux: verifies the user; it unlocks nothing and is never kept.
      const field = el("input", { type: "password", autocomplete: "off", placeholder: "Vault passphrase" });
      const show = el("input", { type: "checkbox", onchange: () => (field.type = show.checked ? "text" : "password") });
      main.append(
        el("h1", { textContent: `Verify it's you for ${item.site}` }),
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
