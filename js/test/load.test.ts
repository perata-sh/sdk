import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";

import { loadPerata, PERATA_SCRIPT_URL, PerataLoadError } from "../src/index.ts";
import type { PerataInstance } from "../src/index.ts";

// A document with only what the loader touches: script tags that can be
// appended, found, removed, and made to load or fail on command.
class FakeScript {
  src = "";
  async = false;
  nonce = "";
  removed = false;
  listeners = new Map<string, Set<() => void>>();
  addEventListener(type: string, listener: () => void): void {
    const set = this.listeners.get(type) ?? new Set();
    set.add(listener);
    this.listeners.set(type, set);
  }
  removeEventListener(type: string, listener: () => void): void {
    this.listeners.get(type)?.delete(listener);
  }
  remove(): void {
    this.removed = true;
    scripts.splice(scripts.indexOf(this), 1);
  }
  fire(type: "load" | "error"): void {
    for (const listener of [...(this.listeners.get(type) ?? [])]) listener();
  }
}

let scripts: FakeScript[] = [];
const fakeWindow: { Perata?: () => PerataInstance } = {};

function instance(tag: string): PerataInstance {
  return { tag } as unknown as PerataInstance;
}

// Each test gets a fresh copy of the loader, because loadPerata remembers loads (load.ts imports no module at run time, so the query string is enough).
let imports = 0;
async function freshLoader(): Promise<typeof import("../src/load.ts")> {
  imports += 1;
  return import(`../src/load.ts?fresh=${imports}`);
}

beforeEach(() => {
  scripts = [];
  delete fakeWindow.Perata;
  Object.assign(globalThis, {
    window: fakeWindow,
    document: {
      head: { appendChild: (script: FakeScript) => scripts.push(script) },
      createElement: () => new FakeScript(),
      querySelectorAll: () => [...scripts],
    },
  });
});

afterEach(() => {
  delete (globalThis as { window?: unknown }).window;
  delete (globalThis as { document?: unknown }).document;
});

test("on the server it resolves with null and touches nothing", async () => {
  delete (globalThis as { window?: unknown }).window;
  delete (globalThis as { document?: unknown }).document;
  const { loadPerata } = await freshLoader();
  assert.equal(await loadPerata(), null);
});

test("it injects the script once and resolves with the instance", async () => {
  const { loadPerata } = await freshLoader();
  const first = loadPerata();
  const second = loadPerata();
  assert.equal(scripts.length, 1);
  const [script] = scripts;
  assert.equal(script?.src, PERATA_SCRIPT_URL);
  assert.equal(script?.async, true);

  fakeWindow.Perata = () => instance("loaded");
  script?.fire("load");

  assert.deepEqual(await first, { tag: "loaded" });
  assert.equal(await first, await second, "both calls share one instance");
  assert.equal(scripts.length, 1);
});

test("a later call after the load reuses the same instance without a new tag", async () => {
  const { loadPerata } = await freshLoader();
  const pending = loadPerata();
  fakeWindow.Perata = () => instance("once");
  scripts[0]?.fire("load");
  const first = await pending;
  assert.equal(await loadPerata(), first);
  assert.equal(scripts.length, 1);
});

test("it uses a window.Perata that is already there and injects nothing", async () => {
  fakeWindow.Perata = () => instance("preloaded");
  const { loadPerata } = await freshLoader();
  assert.deepEqual(await loadPerata(), { tag: "preloaded" });
  assert.equal(scripts.length, 0);
});

test("it waits for a script tag the page already has", async () => {
  const existing = new FakeScript();
  existing.src = PERATA_SCRIPT_URL;
  scripts.push(existing);
  const { loadPerata } = await freshLoader();
  const pending = loadPerata();
  assert.equal(scripts.length, 1, "no second tag");
  fakeWindow.Perata = () => instance("manual-tag");
  existing.fire("load");
  assert.deepEqual(await pending, { tag: "manual-tag" });
  assert.equal(existing.removed, false, "a tag the page owns is never removed");
});

test("scriptUrl and nonce reach the tag", async () => {
  const { loadPerata } = await freshLoader();
  const pending = loadPerata({ scriptUrl: "http://localhost:8080/v1/perata.js", nonce: "abc123" });
  assert.equal(scripts[0]?.src, "http://localhost:8080/v1/perata.js");
  assert.equal(scripts[0]?.nonce, "abc123");
  fakeWindow.Perata = () => instance("local");
  scripts[0]?.fire("load");
  await pending;
});

test("an address that is not https, or http to the local machine, is refused before any tag", async () => {
  const { loadPerata, PerataLoadError } = await freshLoader();
  for (const scriptUrl of ["http://perata.sh/v1/perata.js", "javascript:alert(1)", "not a url", "//perata.sh/v1/perata.js"]) {
    await assert.rejects(loadPerata({ scriptUrl }), (error: unknown) => error instanceof PerataLoadError && error.code === "invalid_url", scriptUrl);
  }
  assert.equal(scripts.length, 0);
});

test("a network error rejects, removes the tag and lets the next call retry", async () => {
  const { loadPerata, PerataLoadError } = await freshLoader();
  const failed = loadPerata();
  scripts[0]?.fire("error");
  await assert.rejects(failed, (error: unknown) => error instanceof PerataLoadError && error.code === "network");
  assert.equal(scripts.length, 0, "the broken tag is gone");

  const retry = loadPerata();
  assert.equal(scripts.length, 1, "a new tag");
  fakeWindow.Perata = () => instance("second-try");
  scripts[0]?.fire("load");
  assert.deepEqual(await retry, { tag: "second-try" });
});

test("a script that loads without defining window.Perata is an error", async () => {
  const { loadPerata, PerataLoadError } = await freshLoader();
  const pending = loadPerata();
  scripts[0]?.fire("load");
  await assert.rejects(pending, (error: unknown) => error instanceof PerataLoadError && error.code === "missing_global");
});

test("it gives up after timeoutMs", async () => {
  const { loadPerata, PerataLoadError } = await freshLoader();
  await assert.rejects(loadPerata({ timeoutMs: 10 }), (error: unknown) => error instanceof PerataLoadError && error.code === "timeout");
  assert.equal(scripts.length, 0);
});

test("the package entry exports the loader, its address and its error", () => {
  const error = new PerataLoadError("timeout", "x");
  assert.equal(error.name, "PerataLoadError");
  assert.ok(error instanceof Error);
  assert.equal(typeof loadPerata, "function");
  assert.equal(PERATA_SCRIPT_URL, "https://perata.sh/v1/perata.js");
});
