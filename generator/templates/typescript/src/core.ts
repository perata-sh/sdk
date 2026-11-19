/** Options for one call. */
export interface RequestOptions {
  /**
   * Makes a write safe to repeat: the same key with the same body answers the
   * first response again; with another body, a 409. A 2xx answer stays under
   * the key; a 4xx or 5xx frees it, so the same key can be sent again. A POST
   * without one is sent with a random UUID of its own, one a call.
   */
  idempotencyKey?: string;
  /** Sends this call with another organization's key. */
  apiKey?: string;
  /** Cancels the call. */
  signal?: AbortSignal;
}

/**
 * A query string's values; undefined ones are left out. A map is a filter sent
 * once for each pair, as name[key]=value, the pairs in the order of their keys.
 */
export type Query = Record<string, string | number | Record<string, string> | undefined>;

export interface RequestSpec {
  query?: Query;
  body?: unknown;
  options?: RequestOptions | undefined;
}

/** What a service calls the API through. */
export interface Requester {
  request<T>(method: string, path: string, spec?: RequestSpec): Promise<T>;
}
