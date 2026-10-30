// passwords/browser §3.1. Run: node --test 'browser/test/*.test.js'
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { kind, classify, submits } = require("../fields.js");

test("autocomplete decides first", () => {
  assert.equal(kind({ type: "text", autocomplete: "one-time-code" }), "code");
  assert.equal(kind({ type: "text", autocomplete: "username" }), "username");
  assert.equal(kind({ type: "password", autocomplete: "new-password" }), "password");
});

test("GitHub's sign-in and two-factor fields", () => {
  assert.deepEqual(
    classify([{ type: "text", name: "login", id: "login_field" }, { type: "password", name: "password" }]),
    ["username", "password"],
  );
  assert.equal(kind({ type: "text", name: "app_otp", id: "app_totp", autocomplete: "one-time-code" }), "code");
  assert.equal(kind({ type: "text", name: "app_otp" }), "code", "without autocomplete, by name");
});

test("Chromium's code pattern over name, id and label", () => {
  assert.equal(kind({ type: "number", label: "Verification code" }), "code");
  assert.equal(kind({ type: "tel", id: "mfa-token" }), "code");
  assert.equal(kind({ type: "text", placeholder: "Six digit code" }), "code");
});

test("a login or authentication code by its label, never a bare Code", () => {
  assert.deepEqual(classify([{ type: "text", id: "_r_h_", label: "Code", autocomplete: "off" }, { type: "submit" }]), [null, null]);
  assert.equal(kind({ type: "text", label: "Promo code" }), null);
  assert.equal(kind({ type: "text", label: "Login code" }), "code");
  assert.equal(kind({ type: "tel", placeholder: "Authentication code" }), "code");
  assert.equal(kind({ type: "text", label: "Security code" }), null, "a card's CVC");
});

test("Apple's code split in one box per digit is no code field", () => {
  const digit = (n) => ({ type: "tel", autocomplete: "off", label: `Verification Code Digit ${n}` });
  assert.deepEqual(classify([1, 2, 3, 4, 5, 6].map(digit)), [null, null, null, null, null, null]);
  assert.deepEqual(classify([digit(1)]), ["code"], "a single box is the whole code");
});

test("PayNearMe's bank account form is no sign-in", () => {
  const bank = [
    { type: "text", name: "ach_aba_pii", label: "Routing Number" },
    { type: "text", name: "ach_account_pii", label: "Account Number" },
    { type: "text", name: "confirm_ach_account_pii", label: "Re-enter Account Number" },
    { type: "text", name: "name", label: "Account Holder Name" },
  ];
  assert.deepEqual(classify(bank), [null, null, null, null], "by their labels");
  assert.deepEqual(classify([{ type: "text", name: "login", ignored: true }]), [null], "a page's opt-out prevails");
  assert.equal(kind({ type: "text", label: "Account" }), "username");
});

test("a lone text field before a password is its username", () => {
  assert.deepEqual(classify([{ type: "text", name: "q1" }, { type: "password" }]), ["username", "password"]);
  assert.deepEqual(classify([{ type: "text", hidden: true }, { type: "password" }]), [null, "password"]);
});

test("what is never a login field", () => {
  for (const field of [
    { type: "checkbox", name: "remember" },
    { type: "hidden", name: "otp" },
    { type: "password", disabled: true },
    { type: "text", name: "search" },
    { type: "submit", name: "login" },
  ]) assert.equal(kind(field), null, JSON.stringify(field));
});

test("passwords §5.1: the fields that ask for a new password", () => {
  const { newPasswords } = require("../fields.js");
  const marked = [{ type: "password", autocomplete: "new-password" }];
  assert.deepEqual(newPasswords(marked, classify(marked)), [true]);
  const signup = [{ type: "email", name: "email" }, { type: "password", name: "pw" }, { type: "password", name: "pw2" }];
  assert.deepEqual(newPasswords(signup, classify(signup)), [false, true, true]);
  const current = [{ type: "password", autocomplete: "current-password" }, { type: "password" }];
  assert.deepEqual(newPasswords(current, classify(current)), [false, true]);
  const named = [{ type: "text", name: "user" }, { type: "password", name: "password_confirm" }];
  assert.deepEqual(newPasswords(named, classify(named)), [false, true]);
  const signin = [{ type: "text", name: "login" }, { type: "password", name: "password" }];
  assert.deepEqual(newPasswords(signin, classify(signin)), [false, false]);
  const change = [{ type: "password", name: "pw" }, { type: "password", name: "pw1" }, { type: "password", name: "pw2" }];
  assert.deepEqual(newPasswords(change, classify(change)), [false, true, true], "a change form's first is the current one");
  const old = [{ type: "password", name: "old_password" }, { type: "password", name: "password" }];
  assert.deepEqual(newPasswords(old, classify(old)), [false, true], "named the current one");
  const bold = [{ type: "password", name: "bold" }, { type: "password", name: "x" }];
  assert.deepEqual(newPasswords(bold, classify(bold)), [true, true]);
});

test("Google's formless Next submits, its Forgot password does not", () => {
  assert.equal(submits(["Next", null, "", "", "passwordNext"]), true);
  assert.equal(submits(["Forgot password?", null, "", "", "forgotPassword"]), false);
  assert.equal(submits(["", "Show password", "", "", null]), false);
});
