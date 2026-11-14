import type { PerataFactory, PerataInstance } from "./types.ts";

/** Where Peráta.js is served from. */
export const PERATA_SCRIPT_URL = "https://perata.sh/v1/perata.js";

const DEFAULT_TIMEOUT_MS = 15_000;

export interface LoadPerataOptions {
  /**
   * Another address for the script, such as a sandbox or a local server. It
   * must be https; http is accepted only for localhost, 127.0.0.0/8 and ::1.
   * The script serves the checkout of the Peráta that served it.
   */
  scriptUrl?: string;
  /** The CSP nonce for the script tag, when your page requires one. */
  nonce?: string;
  /** Milliseconds before giving up; 15 000 by default. */
  timeoutMs?: number;
}

export type PerataLoadErrorCode = "invalid_url" | "network" | "timeout" | "missing_global";

/** The script could not be loaded or did not define `window.Perata`. */
export class PerataLoadError extends Error {
  readonly code: PerataLoadErrorCode;

  constructor(code: PerataLoadErrorCode, message: string) {
    super(message);
    this.name = "PerataLoadError";
    this.code = code;
  }
}

function checkScriptUrl(scriptUrl: string): string {
  let url: URL;
  try {
    url = new URL(scriptUrl);
  } catch {
    throw new PerataLoadError("invalid_url", "perata: the script URL must be https (http is accepted only for localhost, 127.0.0.0/8 and ::1)");
  }
  const host = url.hostname.toLowerCase();
  const loopback = host === "localhost" || host === "[::1]" || /^127(\.\d{1,3}){3}$/.test(host);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new PerataLoadError("invalid_url", "perata: the script URL must be https (http is accepted only for localhost, 127.0.0.0/8 and ::1)");
  }
  return url.toString();
}

// One load per address: calling loadPerata again, from any component, shares
// the script tag and the instance. A failure is forgotten so a later call retries.
const loads = new Map<string, Promise<PerataInstance>>();

function injectScript(url: string, options: LoadPerataOptions): Promise<PerataFactory> {
  return new Promise((resolve, reject) => {
    const existing = window.Perata;
    if (typeof existing === "function") {
      resolve(existing);
      return;
    }

    let script = Array.from(document.querySelectorAll("script")).find((candidate) => candidate.src === url);
    const created = script === undefined;
    if (script === undefined) {
      script = document.createElement("script");
      script.src = url;
      script.async = true;
      if (options.nonce !== undefined) script.nonce = options.nonce;
    }

    const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const timer = setTimeout(() => settle(new PerataLoadError("timeout", `perata: ${url} did not load within ${timeoutMs} ms`)), timeoutMs);

    const settle = (outcome: PerataFactory | PerataLoadError): void => {
      clearTimeout(timer);
      script.removeEventListener("load", onLoad);
      script.removeEventListener("error", onError);
      if (outcome instanceof PerataLoadError) {
        // A tag that failed would never fire again: take it out so a retry injects a new one.
        if (created) script.remove();
        reject(outcome);
      } else {
        resolve(outcome);
      }
    };
    const onLoad = (): void => {
      const factory = window.Perata;
      settle(typeof factory === "function" ? factory : new PerataLoadError("missing_global", `perata: ${url} loaded but did not define window.Perata`));
    };
    const onError = (): void => settle(new PerataLoadError("network", `perata: could not load ${url}`));

    script.addEventListener("load", onLoad);
    script.addEventListener("error", onError);
    if (created) document.head.appendChild(script);
  });
}

/**
 * Loads Peráta.js once and resolves with its instance, the way
 * `loadStripe` does. On the server (no `window`) it resolves with `null`, so
 * it is safe to call from code that also runs in Next.js or other SSR.
 *
 *     const perata = await loadPerata();
 *     perata?.redirectToCheckout({ url: checkout.url });
 *
 * If `window.Perata` is already there (a script tag of your own), that one is
 * used and nothing is injected.
 */
export function loadPerata(options: LoadPerataOptions = {}): Promise<PerataInstance | null> {
  if (typeof window === "undefined" || typeof document === "undefined") return Promise.resolve(null);

  let url: string;
  try {
    url = checkScriptUrl(options.scriptUrl ?? PERATA_SCRIPT_URL);
  } catch (error) {
    return Promise.reject(error);
  }

  let load = loads.get(url);
  if (load === undefined) {
    load = injectScript(url, options).then((factory) => factory());
    loads.set(url, load);
    load.catch(() => {
      if (loads.get(url) === load) loads.delete(url);
    });
  }
  return load;
}
