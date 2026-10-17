package sh.perata;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** What Peráta posts to an endpoint. */
public final class WebhookEvent {
    private final String id;
    private final String type;
    private final String timestamp;
    private final Map<String, String> data;

    WebhookEvent(String id, String type, String timestamp, Map<String, String> data) {
        this.id = id;
        this.type = type;
        this.timestamp = timestamp;
        this.data = Collections.unmodifiableMap(new LinkedHashMap<>(data));
    }

    /** @return the message's id, the same on every delivery of it */
    public String getId() {
        return id;
    }

    /** @return what happened: checkout_session.succeeded… */
    public String getType() {
        return type;
    }

    /** @return when it happened, RFC 3339 */
    public String getTimestamp() {
        return timestamp;
    }

    /** @return the event's ids and values */
    public Map<String, String> getData() {
        return data;
    }

    @Override
    public String toString() {
        return "WebhookEvent{id=" + id + ", type=" + type + ", timestamp=" + timestamp + ", data=" + data + "}";
    }
}
