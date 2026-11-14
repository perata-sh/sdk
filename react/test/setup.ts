// A browser for React's tests: jsdom's window and document as the globals
// React DOM and Testing Library look for. Import this file before them.
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { url: "https://seller.test/", pretendToBeVisual: true });
const { window } = dom;

for (const name of ["window", "document", "navigator", "HTMLElement", "HTMLIFrameElement", "Node", "Event", "MouseEvent", "MutationObserver", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"]) {
  Object.defineProperty(globalThis, name, { value: name === "window" ? window : (window as unknown as Record<string, unknown>)[name], configurable: true, writable: true });
}

export { window };
