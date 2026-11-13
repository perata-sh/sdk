/**
 * A request the API refused. `code` is the API's: invalid_credential,
 * forbidden, not_found, invalid_request, conflict, idempotency_conflict,
 * body_too_large or unavailable; the usage ingestion adds invalid_events and
 * event_conflict. `fields` says, for invalid_request, what is wrong with each
 * field. `record` is, for the usage ingestion, the position (from 1) in the
 * batch of the event the API refused, and 0 for any other error. `retryAfter`
 * is how many seconds to wait on a 429.
 */
export class PerataError extends Error {
  readonly status: number;
  readonly code: string;
  readonly fields: Record<string, string[]>;
  readonly retryAfter: number | undefined;
  readonly record: number;

  constructor(status: number, code: string, message: string, fields: Record<string, string[]> = {}, retryAfter?: number, record = 0) {
    super(message ? `perata: ${status} ${code}: ${message}` : `perata: ${status} ${code}`);
    this.name = "PerataError";
    this.status = status;
    this.code = code;
    this.fields = fields;
    this.retryAfter = retryAfter;
    this.record = record;
  }

  /** The error a refused response carries. */
  static async from(response: Response): Promise<PerataError> {
    type Problem = { error?: string; message?: string; fields?: Record<string, string[]>; record?: number };
    let body: Problem & { data?: Problem } = {};
    try {
      body = (await response.json()) as typeof body;
    } catch {
      // A refusal without a JSON body is still a refusal.
    }
    // The API's errors are the problem itself; the usage ingestion's are
    // wrapped in data, as its answers are.
    const found: Problem = body.error === undefined && body.data && typeof body.data === "object" ? body.data : body;
    const seconds = Number.parseInt(response.headers.get("retry-after") ?? "", 10);
    return new PerataError(response.status, found.error ?? "", found.message ?? "", found.fields ?? {}, Number.isNaN(seconds) ? undefined : seconds, found.record ?? 0);
  }
}
