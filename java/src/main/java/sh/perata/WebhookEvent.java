package sh.perata;

/**
 * A webhook Peráta sent, verified: one subclass a kind of data
 * ({@link OrderWebhookEvent} carries a {@link WebhookOrder}…), or
 * {@link UnknownWebhookEvent} for a type this SDK does not know yet. Within a
 * class, {@link #getType()} says what happened.
 */
public abstract class WebhookEvent {
    private final String id;
    private final String type;
    private final String timestamp;
    private final String environment;

    WebhookEvent(String id, String type, String timestamp, String environment) {
        this.id = id;
        this.type = type;
        this.timestamp = timestamp;
        this.environment = environment;
    }

    /** @return the message's id, the same as the webhook-id header and on every delivery of it */
    public String getId() {
        return id;
    }

    /** @return what happened: order.paid… */
    public String getType() {
        return type;
    }

    /** @return when it happened, RFC 3339 */
    public String getTimestamp() {
        return timestamp;
    }

    /** @return the environment it happened in, test or live; empty when an older server did not send it */
    public String getEnvironment() {
        return environment;
    }

    /** @return what the event carries */
    public abstract Object getData();

    @Override
    public String toString() {
        return getClass().getSimpleName() + "{id=" + id + ", type=" + type + ", timestamp=" + timestamp + ", environment=" + environment + ", data=" + getData() + "}";
    }
}
