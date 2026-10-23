// passwords/browser: the service worker. The only part that talks to the bridge
// (passwords §9), and the only part that decides what a page may receive. Every
// origin it sends is the browser's (MessageSender.origin), never a page's word.
"use strict";

const HOST = "org.feverdreamtv.tsync";
const missingHost = "tsync is not installed for this browser: run tsync passwords browser install";

// --- the bridge -------------------------------------------------------------

// One native session for a sequence of requests: verify (§5) holds only within
// the session that asked it. A refusal ends the sequence: what follows it is
// never sent (a passkey after a cancelled verification, §5).
function session(messages) {
  return new Promise((resolve) => {
    const replies = [];
    const finish = (reply) => {
      while (replies.length < messages.length) replies.push(reply);
      resolve(replies);
    };
    let port;
    try {
      port = chrome.runtime.connectNative(HOST);
    } catch (e) {
      return finish({ ok: false, code: "unreachable", error: missingHost });
    }
    port.onMessage.addListener((reply) => {
      replies.push(reply);
      if (!reply.ok || replies.length === messages.length) {
        port.disconnect();
        finish(reply.ok ? reply : { ok: false, code: reply.code, error: reply.error });
      } else port.postMessage(messages[replies.length]);
    });
    port.onDisconnect.addListener(() => {
      const why = chrome.runtime.lastError?.message || "";
      finish({ ok: false, code: "unreachable", error: /not found|forbidden/i.test(why) ? missingHost : why || "tsync did not answer" });
    });
    port.postMessage(messages[0]);
  });
}
const one = async (message) => (await session([message]))[0];

// vault §8.1: each domain's look, from the bridge's status, for rows to show.
async function looks() {
  const status = await one({ type: "status" });
  const out = {};
  for (const d of (status.ok && status.domains) || []) if (d.appearance) out[d.domain] = d.appearance;
  return out;
}

// §6: only a web page's frames, by the origin the browser reports.
function originOf(sender) {
  const origin = sender.origin;
  return origin && /^https?:\/\//.test(origin) ? origin : null;
}
const hostOf = (origin) => new URL(origin).host;

async function topOrigin(sender) {
  if (sender.frameId === 0) return originOf(sender);
  try {
    const tab = await chrome.tabs.get(sender.tab.id);
    return tab.url ? new URL(tab.url).origin : null;
  } catch (e) {
    return null;
  }
}

// --- the sheet (§4, §5): the extension's own window ----------------------------

const sheets = new Map();
function sheet(item) {
  const token = crypto.randomUUID();
  return new Promise((resolve) => {
    sheets.set(token, { item, resolve, window: null });
    chrome.windows.create({ url: `sheet.html#${token}`, type: "popup", width: 460, height: 360 }).then(
      (w) => {
        const s = sheets.get(token);
        if (s) s.window = w.id;
      },
      () => {
        sheets.delete(token);
        resolve({ action: "cancel" });
      },
    );
  });
}
chrome.windows.onRemoved.addListener((id) => {
  for (const [token, s] of sheets) if (s.window === id) {
    sheets.delete(token);
    s.resolve({ action: "cancel" });
  }
});
// A page that reloads after its submit, as a sign-in does, brings its window
// back over the sheet: each load raises the sheets still open.
chrome.tabs.onUpdated.addListener((_tab, change) => {
  if (change.status !== "complete") return;
  for (const s of sheets.values()) if (s.window !== null) chrome.windows.update(s.window, { focused: true }).catch(() => {});
});
// An open sheet keeps a port, and pings it, so the worker outlives the user's answer.
chrome.runtime.onConnect.addListener((port) => {
  if (port.name === "sheet") port.onMessage.addListener(() => {});
});

// --- WebAuthn (§5) ------------------------------------------------------------

function b64(buffer) {
  const bytes = new Uint8Array(buffer);
  let text = "";
  for (let i = 0; i < bytes.length; i++) text += String.fromCharCode(bytes[i]);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const unwrap = (v) => (v && v.$b64) || v;

async function clientData(type, publicKey, origin) {
  const json = JSON.stringify({ type, challenge: unwrap(publicKey.challenge), origin, crossOrigin: false });
  const bytes = new TextEncoder().encode(json);
  return { clientDataJSON: b64(bytes), clientDataHash: b64(await crypto.subtle.digest("SHA-256", bytes)) };
}

const asked = (preference) => (preference || "preferred") !== "discouraged";
const refused = (reply) => ({ error: { name: "NotAllowedError", message: reply.error || "refused" } });

// The user verified before the request (§5): the platform's verifier in the same
// session, else the passphrase the sheet asked for. A verifier with no way to ask
// right now (polkit without an agent) answers unreachable, and the passphrase asks.
async function verified(origin, preference, request) {
  if (!asked(preference)) return one(request);
  const status = await one({ type: "status" });
  if (status.ok && status.verifier) {
    const [verify, reply] = await session([{ type: "verify", origin }, request]);
    if (verify.ok || verify.code !== "unreachable") return reply;
  }
  const answer = await sheet({ kind: "passphrase", origin });
  if (answer.action !== "ok") return { ok: false, code: "denied", error: "cancelled" };
  return one({ ...request, passphrase: answer.passphrase });
}

async function webauthnGet(publicKey, origin) {
  const rpId = publicKey.rpId || new URL(origin).hostname;
  const allow = (publicKey.allowCredentials || []).map((c) => unwrap(c.id));
  const found = await one({ type: "passkey_match", origin, rpId, allow });
  if (!found.ok) return refused(found);
  if (!found.passkeys.length) {
    const answer = await sheet(found.locked.length
      ? { kind: "locked", origin, domains: found.locked, device: true }
      : { kind: "passkey-none", origin });
    return answer.action === "fallback" ? { fallback: true } : refused({ error: found.locked.length ? "tsync is locked" : "cancelled" });
  }
  const answer = await sheet({ kind: "passkey-get", origin, passkeys: found.passkeys, looks: await looks() });
  if (answer.action === "fallback") return { fallback: true };
  if (answer.action !== "pick") return refused({ error: "cancelled" });
  const pick = found.passkeys.find((p) => p.id === answer.id);
  const { clientDataJSON, clientDataHash } = await clientData("webauthn.get", publicKey, origin);
  const reply = await verified(origin, publicKey.userVerification,
    { type: "passkey_assert", origin, rpId, domain: pick.domain, id: pick.id, clientDataHash });
  if (!reply.ok) return refused(reply);
  return { credential: { id: reply.credentialId, clientDataJSON, authenticatorData: reply.authenticatorData, signature: reply.signature, userHandle: reply.userHandle } };
}

async function webauthnCreate(publicKey, origin) {
  const rpId = (publicKey.rp && publicKey.rp.id) || new URL(origin).hostname;
  // The owner checks the RP ID against the origin before any sheet names it.
  const check = await one({ type: "passkey_match", origin, rpId, allow: [] });
  if (!check.ok) return { error: { name: "SecurityError", message: check.error } };
  if (check.locked.length) {
    await sheet({ kind: "locked", origin, domains: check.locked, device: false });
    return refused({ error: "tsync is locked" });
  }
  const user = publicKey.user || {};
  // §5: a creation never goes to the browser, whose own manager would keep the passkey.
  const answer = await sheet({ kind: "passkey-create", origin, user: user.name || "" });
  if (answer.action !== "ok") return refused({ error: "cancelled" });
  const { clientDataJSON, clientDataHash } = await clientData("webauthn.create", publicKey, origin);
  const reply = await verified(origin, publicKey.authenticatorSelection?.userVerification, {
    type: "passkey_create", origin, rpId, userHandle: unwrap(user.id), userName: user.name || "",
    userDisplayName: user.displayName || user.name || "",
    algorithms: (publicKey.pubKeyCredParams || []).map((p) => p.alg),
    exclude: (publicKey.excludeCredentials || []).map((c) => unwrap(c.id)),
    clientDataHash,
  });
  if (!reply.ok && reply.code === "exists") return { error: { name: "InvalidStateError", message: "this authenticator already holds a passkey for the site" } };
  if (!reply.ok) return refused(reply);
  return { credential: { id: reply.credentialId, clientDataJSON, attestationObject: reply.attestationObject,
    authenticatorData: reply.authenticatorData, publicKey: reply.publicKey, publicKeyAlgorithm: reply.algorithm } };
}

// --- saving (§4) ----------------------------------------------------------------

// Only after a password the user typed (the content script checks), and with no
// comparison against what tsync holds: the sheet's appearance tells a page nothing.
// §2: an incognito tab leaves nothing in the extension's storage, so its sheet
// has no "Never for this site".
async function offerSave(origin, username, password, incognito) {
  const never = (await chrome.storage.local.get("never")).never || [];
  if (never.includes(origin)) return;
  const match = await one({ type: "match", origin });
  if (!match.ok) return;
  if (match.locked.length && !match.logins.length) {
    await sheet({ kind: "save-failed", origin });
    return;
  }
  const same = match.logins.filter((l) => l.exact && l.username === username);
  const answer = await sheet({ kind: same.length ? "update" : "save", origin, username, title: same[0]?.title, incognito });
  if (answer.action === "never") return chrome.storage.local.set({ never: [...never, origin] });
  if (answer.action !== "ok") return;
  // The domain holding the login updated; a new one goes to the default domain.
  const domain = same[0]?.domain;
  const first = await one({ type: "save", origin, username, password, domain });
  const saved = first.ok && first.update ? await one({ type: "save", origin, username, password, update: first.update, domain }) : first;
  if (!saved.ok) await sheet({ kind: "save-failed", origin, error: saved.error || "tsync could not save it." });
}

// passwords §5.1: the pick is the approval; the login is saved before the form is.
async function suggestFor(origin, username) {
  const reply = await one({ type: "suggest", origin, username });
  if (!reply.ok) return { error: reply.error || "tsync could not suggest a password" };
  return { password: reply.password, id: reply.id, domain: reply.domain };
}

// --- messages ---------------------------------------------------------------------

async function fillFor(origin, m) {
  const reply = await one({ type: "fill", origin, domain: m.domain, id: m.id });
  if (!reply.ok) return { error: reply.error };
  // §3.2: a login matching only by suffix, as tsync says, fills after the user confirms it in the sheet.
  if (!reply.exact) {
    const answer = await sheet({ kind: "fill-suffix", origin, title: m.title, username: reply.username });
    if (answer.action !== "ok") return { error: "cancelled" };
  }
  return m.kind === "code" ? { code: reply.code } : { username: reply.username, password: reply.password };
}

const handlers = {
  async match(m, sender) {
    const origin = originOf(sender);
    if (!origin) return { logins: [] };
    const reply = await one({ type: "match", origin });
    if (!reply.ok) return { error: reply.error };
    const logins = m.kind === "code" ? reply.logins.filter((l) => l.code) : reply.logins;
    return { logins, locked: reply.locked, domains: new Set(reply.logins.map((l) => l.domain)).size, looks: await looks() };
  },
  async fill(m, sender) {
    const origin = originOf(sender);
    return origin ? fillFor(origin, m) : { error: "not a web page" };
  },
  async suggest(m, sender) {
    const origin = originOf(sender);
    if (!origin) return { error: "no origin" };
    return suggestFor(origin, m.username || "");
  },
  // §5.1: the submit after a suggestion sets the username of the login it saved.
  async "save-suggested"(m, sender) {
    const origin = originOf(sender);
    if (origin) await one({ type: "save", origin, username: m.username, suggested: m.id, domain: m.domain });
    return {};
  },
  async "offer-save"(m, sender) {
    const origin = originOf(sender);
    if (origin) offerSave(origin, m.username, m.password, sender.tab?.incognito === true);
    return {};
  },
  // A conditional request is held only when tsync has passkeys for it; otherwise it
  // is left unanswered, never given to the browser's own conditional UI (§5).
  async "passkey-conditional"(m, sender) {
    const origin = originOf(sender);
    if (!origin || origin !== (await topOrigin(sender))) return { hold: false };
    const rpId = m.publicKey.rpId || new URL(origin).hostname;
    const reply = await one({ type: "passkey_match", origin, rpId, allow: (m.publicKey.allowCredentials || []).map((c) => unwrap(c.id)) });
    return { hold: reply.ok && reply.passkeys.length > 0 };
  },
  async webauthn(m, sender) {
    const origin = originOf(sender);
    if (!origin) return refused({ error: "no origin" });
    // §5: tsync cannot honour a cross-origin frame's permissions policy; the user may
    // take a sign-in to a phone or security key, never a creation to the browser.
    const top = await topOrigin(sender);
    if (origin !== top) {
      const answer = await sheet({ kind: "frame", origin, top, device: m.kind !== "create" });
      return answer.action === "fallback" ? { fallback: true } : refused({ error: "cancelled" });
    }
    try {
      return m.kind === "create" ? await webauthnCreate(m.publicKey, origin) : await webauthnGet(m.publicKey, origin);
    } catch (e) {
      return { error: { name: "NotAllowedError", message: String(e) } };
    }
  },
  async "sheet-item"(m) {
    const s = sheets.get(m.token);
    return s ? s.item : null;
  },
  async "sheet-answer"(m) {
    const s = sheets.get(m.token);
    if (s) {
      sheets.delete(m.token);
      s.resolve(m.answer);
    }
    return {};
  },
  // The popup asks for the tab it was opened over, by the tab's URL as the browser has it.
  async "popup-state"(m) {
    const tab = await chrome.tabs.get(m.tabId);
    const origin = tab.url && /^https?:/.test(tab.url) ? new URL(tab.url).origin : null;
    const [status, match] = await session([{ type: "status" }, ...(origin ? [{ type: "match", origin }] : [])]);
    return { origin, status, match: match || null };
  },
  async "popup-fill"(m) {
    const tab = await chrome.tabs.get(m.tabId);
    const origin = new URL(tab.url).origin;
    const values = await fillFor(origin, m);
    if (values.error || m.kind === "code") return values;
    // §3.2: the content script applies it only if its document is still that origin.
    try {
      await chrome.tabs.sendMessage(m.tabId, { type: "apply", origin, values }, { frameId: 0 });
    } catch (e) {
      return { error: "this page has no tsync on it yet: reload it" };
    }
    return {};
  },
};

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  const handler = handlers[message.type];
  if (!handler) return false;
  // The sheet and the popup are the extension's own pages; a content script is
  // never answered for them.
  const own = sender.url && sender.url.startsWith(chrome.runtime.getURL(""));
  if ((message.type.startsWith("sheet-") || message.type.startsWith("popup-")) !== own) return false;
  handler(message, sender).then(reply, (e) => reply({ error: String(e) }));
  return true;
});

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "fill") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab) chrome.tabs.sendMessage(tab.id, { type: "open-menu" }).catch(() => {});
});

// §3.3: once installed, the extension turns off the browser's own password saving, so
// nothing lands there by default; the popup gives it back on the user's choice.
const BROWSER_OWN = ["passwordSavingEnabled", "autofillAddressEnabled", "autofillCreditCardEnabled"];
chrome.runtime.onInstalled.addListener(({ reason }) => {
  if (reason !== "install") return;
  for (const name of BROWSER_OWN) chrome.privacy?.services?.[name]?.set({ value: false }).catch(() => {});
});
