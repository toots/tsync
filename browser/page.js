// passwords/browser §5: in the page's world, a wrapper of navigator.credentials
// for publicKey requests. It holds nothing and decides nothing: it forwards the
// options to the content script and builds the page's credential from the
// reply. The origin the owner signs over is the browser's, never this script's.
"use strict";

(() => {
  if (!navigator.credentials || window.__tsyncWebauthn) return;
  window.__tsyncWebauthn = true;
  const original = {
    create: navigator.credentials.create.bind(navigator.credentials),
    get: navigator.credentials.get.bind(navigator.credentials),
  };
  const pending = new Map();
  let next = 0;

  const toB64 = (buffer) => {
    const bytes = buffer instanceof ArrayBuffer ? new Uint8Array(buffer) : new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    let text = "";
    for (const b of bytes) text += String.fromCharCode(b);
    return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };
  const fromB64 = (text) => {
    const raw = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4));
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes.buffer;
  };
  const isBuffer = (v) => v instanceof ArrayBuffer || ArrayBuffer.isView(v);

  // The options as plain JSON, binary members in base64url.
  function plain(value) {
    if (isBuffer(value)) return { $b64: toB64(value) };
    if (Array.isArray(value)) return value.map(plain);
    if (value && typeof value === "object") {
      const out = {};
      for (const [k, v] of Object.entries(value)) if (k !== "signal") out[k] = plain(v);
      return out;
    }
    return value;
  }

  window.addEventListener("message", (event) => {
    const m = event.data;
    if (event.source !== window || !m || m.tsync !== "webauthn-reply") return;
    const waiter = pending.get(m.id);
    if (!waiter) return;
    pending.delete(m.id);
    waiter(m);
  });

  function ask(kind, options) {
    const id = `${Date.now()}-${next++}`;
    return new Promise((resolve) => {
      pending.set(id, resolve);
      window.postMessage({ tsync: "webauthn", id, kind, mediation: options.mediation || null, publicKey: plain(options.publicKey) }, window.location.origin);
      options.signal?.addEventListener("abort", () => {
        pending.delete(id);
        resolve({ aborted: true });
      });
    });
  }

  // A credential the page can read like the browser's: own properties shadow the
  // prototype's getters, which would refuse an object the browser did not make.
  function credential(r) {
    const response = r.attestationObject
      ? {
          clientDataJSON: fromB64(r.clientDataJSON),
          attestationObject: fromB64(r.attestationObject),
          getAuthenticatorData: () => fromB64(r.authenticatorData),
          getPublicKey: () => fromB64(r.publicKey),
          getPublicKeyAlgorithm: () => r.publicKeyAlgorithm,
          getTransports: () => ["internal", "hybrid"],
        }
      : {
          clientDataJSON: fromB64(r.clientDataJSON),
          authenticatorData: fromB64(r.authenticatorData),
          signature: fromB64(r.signature),
          userHandle: r.userHandle ? fromB64(r.userHandle) : null,
        };
    const json = {
      id: r.id, rawId: r.id, type: "public-key", authenticatorAttachment: "platform",
      response: r.attestationObject
        ? { clientDataJSON: r.clientDataJSON, attestationObject: r.attestationObject, authenticatorData: r.authenticatorData,
            publicKey: r.publicKey, publicKeyAlgorithm: r.publicKeyAlgorithm, transports: ["internal", "hybrid"] }
        : { clientDataJSON: r.clientDataJSON, authenticatorData: r.authenticatorData, signature: r.signature, userHandle: r.userHandle },
      clientExtensionResults: r.attestationObject ? { credProps: { rk: true } } : {},
    };
    const made = {
      id: r.id,
      rawId: fromB64(r.id),
      type: "public-key",
      authenticatorAttachment: "platform",
      response,
      getClientExtensionResults: () => json.clientExtensionResults,
      toJSON: () => json,
    };
    if (typeof PublicKeyCredential !== "undefined") Object.setPrototypeOf(made, PublicKeyCredential.prototype);
    return made;
  }

  async function through(kind, options) {
    if (!options || !options.publicKey) return original[kind](options);
    const reply = await ask(kind, options);
    if (reply.aborted) throw new DOMException("The operation was aborted.", "AbortError");
    if (reply.fallback) return original[kind](options);
    if (reply.error) throw new DOMException(reply.error.message, reply.error.name);
    return credential(reply.credential);
  }

  navigator.credentials.create = (options) => through("create", options);
  navigator.credentials.get = (options) => through("get", options);
})();
