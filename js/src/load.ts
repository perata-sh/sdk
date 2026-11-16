import type { PerataFactory, PerataInstance } from "./types.ts";

/** Where Peráta.js is served from. */
export const PERATA_SCRIPT_URL = "https://perata.sh/v1/perata.js";

const DEFAULT_TIMEOUT_MS = 15_000;

/**
 * A fixed version of the script: the address that carries the hash of its
 * content (`/v1/perata.<hash>.js`, which never changes) and the integrity value
 * of the same bytes. The browser refuses a script that is not exactly the one
 * you read. Both are published in Configurações › Como integrar, in the panel,
 * for each release of the script.
 */
export interface PerataScriptPin {
  /** The first 16 hexadecimal digits of the content's SHA-256, as the address carries them. */
  hash: string;
  /** The Subresource Integrity value: `sha384-` and the base64 of the SHA-384 of the content. */
  integrity: string;
}

export interface LoadPerataOptions {
  /**
   * Another address for the script, such as a sandbox or a local server. It
   * must be https; http is accepted only for localhost, 127.0.0.0/8 and ::1.
   * The script serves the checkout of the Peráta that served it. With `pin`,
   * only its origin is used.
   */
  scriptUrl?: string;
  /**
   * Loads one fixed version of the script, with its integrity check, instead of
   * the one that receives every fix within minutes. A new release of the script
   * is a new hash and a new integrity value: update both to take it.
   */
  pin?: PerataScriptPin;
  /** The CSP nonce for the script tag, when your page requires one. */
  nonce?: string;
  /** Milliseconds before giving up; 15 000 by default. */
  timeoutMs?: number;
}

export type PerataLoadErrorCode = "invalid_url" | "invalid_pin" | "network" | "timeout" | "missing_global";

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

const PIN_HASH = /^[0-9a-f]{16}$/;
const PIN_INTEGRITY = /^sha(256|384|512)-[A-Za-z0-9+/]{43,}={0,2}$/;

/** The address of the pinned script: the same origin, the path the hash names. */
function pinnedUrl(scriptUrl: string, pin: PerataScriptPin): string {
  if (typeof pin !== "object" || pin === null || !PIN_HASH.test(pin.hash) || !PIN_INTEGRITY.test(pin.integrity)) {
    throw new PerataLoadError("invalid_pin", "perata: pin needs the script's hash (16 hexadecimal digits) and its integrity value (sha384-…)");
  }
  const url = new URL(scriptUrl);
  url.pathname = `/v1/perata.${pin.hash}.js`;
  url.search = "";
  url.hash = "";
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
      if (options.pin !== undefined) {
        // The browser checks the bytes against the integrity value, which it
        // may do for a script of another origin only with CORS: the pinned
        // address answers to every origin.
        script.integrity = options.pin.integrity;
        script.crossOrigin = "anonymous";
      }
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
 *
 * To fix the version, pass the `pin` of a release (its hash and its integrity
 * value): the script is then loaded from the address that carries the hash and
 * the browser checks it against the integrity value.
 */
export function loadPerata(options: LoadPerataOptions = {}): Promise<PerataInstance | null> {
  if (typeof window === "undefined" || typeof document === "undefined") return Promise.resolve(null);

  let url: string;
  try {
    url = checkScriptUrl(options.scriptUrl ?? PERATA_SCRIPT_URL);
    if (options.pin !== undefined) url = pinnedUrl(url, options.pin);
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
