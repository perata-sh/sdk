defmodule Perata.WebhookEvent do
  @moduledoc "What Peráta posts to an endpoint."

  @enforce_keys [:id, :type, :timestamp, :data]
  defstruct [:id, :type, :timestamp, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          timestamp: String.t(),
          data: %{optional(String.t()) => String.t()}
        }
end

defmodule Perata.WebhookVerificationError do
  @moduledoc "A request Peráta did not sign, or signed too long ago."

  defexception message: "perata: webhook signature does not verify"

  @type t :: %__MODULE__{message: String.t()}
end

defmodule Perata.Webhook do
  @moduledoc """
  Verifying the webhooks Peráta sends, as Standard Webhooks signs them.

      {:ok, event} = Perata.Webhook.verify(secret, conn.req_headers, raw_body)
  """

  @tolerance_seconds 300

  @doc "How far from now a webhook's timestamp may be, in seconds."
  @spec tolerance_seconds() :: pos_integer()
  def tolerance_seconds, do: @tolerance_seconds

  @doc """
  Checks a webhook Peráta sent and answers its event.

  The signature is an HMAC-SHA256 of `{webhook-id}.{webhook-timestamp}.{body}`
  under the key the endpoint's `whsec_` secret encodes. Pass the body exactly
  as it arrived, before parsing it; `headers` is a map or a list of name and
  value pairs, names in any case. The option `:now` is the Unix time to check
  the timestamp against.

  A secret that is not `whsec_` and a base64 key raises `ArgumentError`.
  """
  @spec verify(String.t(), Enumerable.t(), binary(), keyword()) ::
          {:ok, Perata.WebhookEvent.t()} | {:error, Perata.WebhookVerificationError.t()}
  def verify(secret, headers, body, opts \\ []) when is_binary(body) do
    key =
      case Base.decode64(String.replace_prefix(secret, "whsec_", "")) do
        {:ok, key} when key != "" -> key
        _ -> raise ArgumentError, "perata: the webhook secret is whsec_ and a base64 key"
      end

    now = opts |> Keyword.get_lazy(:now, fn -> System.os_time(:second) end) |> unix()
    id = header(headers, "webhook-id")
    stamp = header(headers, "webhook-timestamp")

    with true <- id != "",
         {seconds, ""} <- Integer.parse(stamp),
         true <- abs(now - seconds) <= @tolerance_seconds,
         expected = :crypto.mac(:hmac, :sha256, key, [id, ".", stamp, ".", body]),
         true <-
           Enum.any?(String.split(header(headers, "webhook-signature")), &signs?(&1, expected)),
         {:ok, %{} = event} <- JSON.decode(body) do
      {:ok,
       %Perata.WebhookEvent{
         id: event["id"],
         type: event["type"],
         timestamp: event["timestamp"],
         data: event["data"] || %{}
       }}
    else
      _ -> {:error, %Perata.WebhookVerificationError{}}
    end
  end

  defp signs?("v1," <> encoded, expected) do
    case Base.decode64(encoded) do
      {:ok, decoded} when byte_size(decoded) == byte_size(expected) ->
        :crypto.hash_equals(decoded, expected)

      _ ->
        false
    end
  end

  defp signs?(_signature, _expected), do: false

  defp header(headers, name) do
    Enum.find_value(headers, "", fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)
  defp unix(seconds) when is_integer(seconds), do: seconds
end
