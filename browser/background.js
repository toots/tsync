// passwords/browser: the service worker. The only part that talks to the bridge
// (passwords §9), and the only part that decides what a page may receive. Every
// origin it sends is the browser's (MessageSender.origin), never a page's word.
"use strict";

const HOST = "org.feverdreamtv.tsync";

// --- the bridge -------------------------------------------------------------

// One native session for a sequence of requests: verify (§5) holds only within
// the session that asked it.
function session(messages) {
  return new Promise((resolve) => {
    let port;
    try {
      port = chrome.runtime.connectNative(HOST);
    } catch (e) {
      return resolve(messages.map(() => ({ ok: false, code: "unreachable", error: missingHost })));
    }
    const replies = [];
    let i = 0;
    port.onMessage.addListener((reply) => {
      replies.push(reply);
      i++;
      if (i < messages.length) port.postMessage(messages[i]);
      else {
        port.disconnect();
        resolve(replies);
      }
    });
    port.onDisconnect.addListener(() => {
      const why = chrome.runtime.lastError?.message || "";
      const error = /not found|forbidden/i.test(why) ? missingHost : why || "tsync did not answer";
      while (replies.length < messages.length) replies.push({ ok: false, code: "unreachable", error });
      resolve(replies);
    });
    port.postMessage(messages[0]);
  });
}
const missingHost = "tsync is not installed for this browser: run tsync passwords browser install";
const one = async (message) => (await session([message]))[0];

// §6: only a web page's frames, by the origin the browser reports.
function originOf(sender) {
  const origin = sender.origin || (sender.url && new URL(sender.url).origin);
  if (!origin || !/^https?:\/\//.test(origin)) return null;
  return origin;
}

// --- the sheet (§4, §5): the extension's own window ----------------------------

const sheets = new Map();
function sheet(item) {
  const token = crypto.randomUUID();
  return new Promise((resolve) => {
    sheets.set(token, { item, resolve });
    chrome.windows.create({ url: `sheet.html#${token}`, type: "popup", width: 440, height: 340 }, (w) => {
      sheets.get(token).window = w.id;
    });
  });
}
chrome.windows.onRemoved.addListener((id) => {
  for (const [token, s] of sheets) if (s.window === id) {
    sheets.delete(token);
    s.resolve({ action: "cancel" });
  }
});

// --- WebAuthn (§5) ------------------------------------------------------------

const b64 = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const text = (s) => new TextEncoder().encode(s);
const unwrap = (v) => (v && v.$b64) || v;

async function clientData(type, publicKey, origin, crossOrigin) {
  const json = JSON.stringify({ type, challenge: unwrap(publicKey.challenge), origin, crossOrigin });
  const hash = await crypto.subtle.digest("SHA-256", text(json));
  return { clientDataJSON: b64(text(json)), clientDataHash: b64(hash) };
}

const asked = (preference) => (preference || "preferred") !== "discouraged";

async function verifier() {
  const status = await one({ type: "status" });
  return status.ok ? status.verifier : null;
}

// The user verified before the request (§5): the platform's verifier in the same
// session, else the passphrase the sheet asked for.
async function verified(origin, preference, request, passphraseItem) {
  if (!asked(preference)) return session([request]).then((r) => r[0]);
  if (await verifier()) {
    const [check, reply] = await session([{ type: "verify", origin }, request]);
    return check.ok ? reply : check;
  }
  const answer = await sheet(passphraseItem);
  if (answer.action !== "ok") return { ok: false, code: "denied", error: "cancelled" };
  return one({ ...request, passphrase: answer.passphrase });
}

async function webauthnGet(publicKey, origin, crossOrigin, chosen) {
  const rpId = publicKey.rpId || new URL(origin).hostname;
  const allow = (publicKey.allowCredentials || []).map((c) => unwrap(c.id));
  let pick = chosen;
  if (!pick) {
    const found = await one({ type: "passkey_match", origin, rpId, allow });
    if (!found.ok || !found.passkeys.length) return { fallback: true };
    const answer = await sheet({ kind: "passkey-get", site: rpId, passkeys: found.passkeys });
    if (answer.action !== "pick") return { fallback: true };
    pick = found.passkeys.find((p) => p.id === answer.id);
  }
  const { clientDataJSON, clientDataHash } = await clientData("webauthn.get", publicKey, origin, crossOrigin);
  const reply = await verified(origin, publicKey.userVerification,
    { type: "passkey_assert", origin, rpId, domain: pick.domain, id: pick.id, clientDataHash },
    { kind: "passphrase", site: rpId });
  if (!reply.ok) return { error: { name: "NotAllowedError", message: reply.error } };
  return { credential: { id: reply.credentialId, clientDataJSON, authenticatorData: reply.authenticatorData, signature: reply.signature, userHandle: reply.userHandle } };
}

async function webauthnCreate(publicKey, origin, crossOrigin) {
  const rpId = (publicKey.rp && publicKey.rp.id) || new URL(origin).hostname;
  const user = publicKey.user || {};
  const answer = await sheet({ kind: "passkey-create", site: rpId, user: user.name || "" });
  if (answer.action !== "ok") return { fallback: true };
  const { clientDataJSON, clientDataHash } = await clientData("webauthn.create", publicKey, origin, crossOrigin);
  const reply = await verified(origin, publicKey.authenticatorSelection?.userVerification, {
    type: "passkey_create", origin, rpId, userHandle: unwrap(user.id), userName: user.name || "",
    userDisplayName: user.displayName || user.name || "",
    algorithms: (publicKey.pubKeyCredParams || []).map((p) => p.alg),
    exclude: (publicKey.excludeCredentials || []).map((c) => unwrap(c.id)),
    clientDataHash,
  }, { kind: "passphrase", site: rpId });
  if (!reply.ok && reply.code === "exists") return { error: { name: "InvalidStateError", message: "this authenticator already holds a passkey for the site" } };
  if (!reply.ok) return { error: { name: "NotAllowedError", message: reply.error } };
  return { credential: { id: reply.credentialId, clientDataJSON, attestationObject: reply.attestationObject,
    authenticatorData: reply.authenticatorData, publicKey: reply.publicKey, publicKeyAlgorithm: reply.algorithm } };
}

// --- saving (§4) ----------------------------------------------------------------

async function offerSave(origin, username, password) {
  const never = (await chrome.storage.local.get("never")).never || [];
  if (never.includes(origin)) return;
  // Ask only when tsync lacks this login or holds another password for it.
  const match = await one({ type: "match", origin });
  if (!match.ok) return;
  const same = (match.logins || []).filter((l) => l.username === username);
  for (const login of same) {
    const filled = await one({ type: "fill", origin, domain: login.domain, id: login.id });
    if (filled.ok && filled.password === password) return;
  }
  const answer = await sheet({ kind: same.length ? "update" : "save", site: origin, username, title: same[0]?.title });
  if (answer.action === "never") {
    await chrome.storage.local.set({ never: [...never, origin] });
    return;
  }
  if (answer.action !== "ok") return;
  const first = await one({ type: "save", origin, username, password });
  if (first.ok && first.update) await one({ type: "save", origin, username, password, update: first.update });
}

// --- messages ---------------------------------------------------------------------

const handlers = {
  async match(m, sender) {
    const origin = originOf(sender);
    if (!origin) return { logins: [] };
    const reply = await one({ type: "match", origin });
    if (!reply.ok) return { error: reply.error };
    const logins = m.kind === "code" ? reply.logins.filter((l) => l.code) : reply.logins;
    return { logins, locked: reply.locked, domains: new Set(reply.logins.map((l) => l.domain)).size };
  },
  async fill(m, sender) {
    const origin = originOf(sender);
    if (!origin) return { error: "not a web page" };
    const reply = await one({ type: "fill", origin, domain: m.domain, id: m.id });
    return reply.ok ? { username: reply.username, password: reply.password, code: reply.code } : { error: reply.error };
  },
  async "offer-save"(m, sender) {
    const origin = originOf(sender);
    if (origin) offerSave(origin, m.username, m.password);
    return {};
  },
  async "passkey-options"(m, sender) {
    const origin = originOf(sender);
    if (!origin) return { passkeys: [] };
    const rpId = m.publicKey.rpId || new URL(origin).hostname;
    const reply = await one({ type: "passkey_match", origin, rpId, allow: (m.publicKey.allowCredentials || []).map((c) => unwrap(c.id)) });
    return { passkeys: reply.ok ? reply.passkeys : [] };
  },
  async webauthn(m, sender) {
    const origin = originOf(sender);
    if (!origin) return { fallback: true };
    const crossOrigin = sender.frameId !== 0;
    return m.kind === "create" ? webauthnCreate(m.publicKey, origin, crossOrigin) : webauthnGet(m.publicKey, origin, crossOrigin, m.chosen);
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
    const reply = await one({ type: "fill", origin, domain: m.domain, id: m.id });
    if (!reply.ok) return { error: reply.error };
    if (m.copyCode) return { code: reply.code };
    await chrome.tabs.sendMessage(m.tabId, { type: "apply", values: { username: reply.username, password: reply.password } }, { frameId: 0 });
    return {};
  },
};

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  const handler = handlers[message.type];
  if (!handler) return false;
  // The sheet and the popup are the extension's own pages; a content script is
  // never answered for them.
  if ((message.type.startsWith("sheet-") || message.type.startsWith("popup-")) && sender.url && !sender.url.startsWith(chrome.runtime.getURL(""))) return false;
  handler(message, sender).then(reply, (e) => reply({ error: String(e) }));
  return true;
});

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== "fill") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab) chrome.tabs.sendMessage(tab.id, { type: "open-menu" });
});
