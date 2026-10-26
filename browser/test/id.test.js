// passwords/browser §2. Run: node --test 'browser/test/*.test.js'
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..", "..");

// Chrome's id: the key's SHA-256, first 16 bytes, each hex digit spelled a to p.
function idOfKey(key) {
  const hex = crypto.createHash("sha256").update(Buffer.from(key, "base64")).digest("hex");
  return [...hex.slice(0, 32)].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join("");
}

test("the manifest's key gives the id the native host allows", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "browser", "manifest.json"), "utf8"));
  const cmds = fs.readFileSync(path.join(root, "bin", "passwords_cmds.ml"), "utf8");
  const allowed = cmds.match(/let extension_id = "([a-p]{32})"/);
  assert.ok(allowed, "extension_id not found in bin/passwords_cmds.ml");
  assert.equal(idOfKey(manifest.key), allowed[1]);
});
