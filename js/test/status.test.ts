import assert from "node:assert/strict";
import { test } from "node:test";

import { isFinalStatus } from "../src/index.ts";

test("succeeded, failed and expired are final; open and confirmed are not", () => {
  for (const status of ["succeeded", "failed", "expired"] as const) assert.equal(isFinalStatus(status), true, status);
  for (const status of ["open", "confirmed"] as const) assert.equal(isFinalStatus(status), false, status);
});
