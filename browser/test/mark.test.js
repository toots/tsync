// vault §8.1. Run: node --test 'browser/test/*.test.js'
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { byVault } = require("../mark.js");

test("rows group by vault in name order, each vault's rows in their own order", () => {
  const rows = [{ domain: "Work", id: 1 }, { domain: "Files", id: 2 }, { domain: "Work", id: 3 }];
  assert.deepEqual(byVault(rows).map((g) => [g.domain, g.items.map((r) => r.id)]), [["Files", [2]], ["Work", [1, 3]]]);
});

test("one vault is one group, so no header is drawn", () => {
  assert.equal(byVault([{ domain: "Files" }, { domain: "Files" }]).length, 1);
  assert.equal(byVault([]).length, 0);
});
