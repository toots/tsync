// passwords/browser §3.1: what a field is, as Chromium's own autofill tells it.
// A plain script: the content script loads it first, and node's tests require it.
"use strict";

const TsyncFields = (() => {
  // Chromium's ONE_TIME_CODE pattern (form_parsing legacy_regex_patterns.json),
  // plus mfa, one-time and the login or authentication code (a "security code" is a card's CVC).
  const CODE_NAME = /otp|verification.code|2fa|six.digit|mfa|one.time|(login|auth\w*).code/i;
  const USERNAME_NAME = /user.?name|login|e.?mail|account|identifier/i;

  // A field is described by plain data, so the rule can be tested without a DOM.
  function kind(field) {
    if (field.hidden || field.disabled || field.readOnly) return null;
    const type = (field.type || "text").toLowerCase();
    if (!["text", "email", "password", "tel", "number", "search", ""].includes(type)) return null;
    const autocomplete = (field.autocomplete || "").toLowerCase().split(/\s+/);
    if (autocomplete.includes("one-time-code")) return "code";
    if (autocomplete.includes("current-password") || autocomplete.includes("new-password")) return "password";
    if (autocomplete.includes("username") || autocomplete.includes("email")) return "username";
    if (type === "password") return "password";
    const names = [field.name, field.id, field.label, field.placeholder].filter(Boolean).join(" ");
    if (CODE_NAME.test(names)) return "code";
    if (type === "email" || USERNAME_NAME.test(names)) return "username";
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
  // so, one named so, or every password field of a form that has two.
  const NEW_NAME = /new|confirm|repeat|retype|again|sign.?up|regist|creat/i;
  function newPasswords(fields, kinds) {
    const passwords = kinds.filter((k) => k === "password").length;
    return fields.map((field, i) => {
      if (kinds[i] !== "password") return false;
      const autocomplete = (field.autocomplete || "").toLowerCase().split(/\s+/);
      if (autocomplete.includes("new-password")) return true;
      if (autocomplete.includes("current-password")) return false;
      if (passwords >= 2) return true;
      return NEW_NAME.test([field.name, field.id, field.label, field.placeholder].filter(Boolean).join(" "));
    });
  }

  return { kind, classify, newPasswords };
})();

if (typeof module !== "undefined") module.exports = TsyncFields;
