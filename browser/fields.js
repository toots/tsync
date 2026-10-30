// passwords/browser §3.1: what a field is, as Chromium's own autofill tells it.
// A plain script: the content script loads it first, and node's tests require it.
"use strict";

const TsyncFields = (() => {
  // Chromium's ONE_TIME_CODE pattern (form_parsing legacy_regex_patterns.json),
  // plus mfa, one-time and the login or authentication code (a "security code" is a card's CVC).
  const CODE_NAME = /otp|verification.code|2fa|six.digit|mfa|one.time|(login|auth\w*).code/i;
  const USERNAME_NAME = /user.?name|login|e.?mail|account|identifier/i;
  const NOT_USERNAME = /account.?(n(o|um)|holder)|routing/i;

  // A field is described by plain data, so the rule can be tested without a DOM;
  // [ignored] is a page's opt-out from password managers, as 1Password, LastPass and Bitwarden honor it.
  function kind(field) {
    if (field.hidden || field.disabled || field.readOnly || field.ignored) return null;
    const type = (field.type || "text").toLowerCase();
    if (!["text", "email", "password", "tel", "number", "search", ""].includes(type)) return null;
    const autocomplete = (field.autocomplete || "").toLowerCase().split(/\s+/);
    if (autocomplete.includes("one-time-code")) return "code";
    if (autocomplete.includes("current-password") || autocomplete.includes("new-password")) return "password";
    if (autocomplete.includes("username") || autocomplete.includes("email")) return "username";
    if (type === "password") return "password";
    const names = [field.name, field.id, field.label, field.placeholder].filter(Boolean).join(" ");
    if (CODE_NAME.test(names)) return "code";
    if (type === "email" || (USERNAME_NAME.test(names) && !NOT_USERNAME.test(names))) return "username";
    return null;
  }

  // The fields of one form: a lone text field before a password field is its
  // username, as most sign-in pages draw it, and several code fields are one code split in boxes, which tsync does not fill.
  function classify(fields) {
    const kinds = fields.map(kind);
    if (kinds.filter((k) => k === "code").length > 1) kinds.forEach((k, i) => { if (k === "code") kinds[i] = null; });
    const firstPassword = kinds.indexOf("password");
    if (firstPassword > 0 && !kinds.includes("username")) {
      for (let i = firstPassword - 1; i >= 0; i--) {
        const type = (fields[i].type || "text").toLowerCase();
        if (kinds[i] === null && (type === "text" || type === "email" || type === "") && !fields[i].hidden) {
          kinds[i] = "username";
          break;
        }
      }
    }
    return kinds;
  }

  // passwords §5.1: the password fields that ask for a new password: one marked
  // so, one named so, or, in a form of two or three, every one but a third's first.
  const NEW_NAME = /new|confirm|repeat|retype|again|sign.?up|regist|creat/i;
  const CURRENT_NAME = /current|(^|[^a-z])old|existing/i;
  function newPasswords(fields, kinds) {
    const passwords = kinds.flatMap((k, i) => (k === "password" ? [i] : []));
    return fields.map((field, i) => {
      if (kinds[i] !== "password") return false;
      const autocomplete = (field.autocomplete || "").toLowerCase().split(/\s+/);
      if (autocomplete.includes("new-password")) return true;
      if (autocomplete.includes("current-password")) return false;
      const names = [field.name, field.id, field.label, field.placeholder].filter(Boolean).join(" ");
      if (CURRENT_NAME.test(names)) return false;
      if (passwords.length >= 3) return i !== passwords[0];
      return passwords.length === 2 || NEW_NAME.test(names);
    });
  }

  // A button outside a form is a sign-in's only when its names say nothing else: a page drawing
  // its sign-in by script puts Next beside Forgot password, both plain buttons.
  // ponytail: English names only; a page's ids are English more often than its labels.
  const NOT_SUBMIT = /forgot|reset|recover|help|cancel|back|show|hide|try.another|create|sign.?up|regist/i;
  const submits = (names) => !NOT_SUBMIT.test(names.filter(Boolean).join(" "));

  // A sign-in asking the password on a later step keeps its username out of sight: hidden or read-only.
  // A type="hidden" field also carries tokens (login_challenge), so only its exact name makes it a username.
  function keptUsername(field) {
    if (!(field.hidden || field.readOnly || field.disabled)) return false;
    if (field.type === "hidden" && !/^(user.?name|e.?mail|identifier|login)$/i.test(field.name || field.id || "")) return false;
    const shown = { ...field, type: field.type === "hidden" ? "text" : field.type, hidden: false, readOnly: false, disabled: false };
    return kind(shown) === "username";
  }

  return { kind, classify, newPasswords, submits, keptUsername };
})();

if (typeof module !== "undefined") module.exports = TsyncFields;
