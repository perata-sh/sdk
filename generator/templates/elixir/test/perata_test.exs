# Peráta's Elixir SDK tests, with nothing to install: mix test

defmodule PerataTest do
  use ExUnit.Case, async: true

  # A client whose transport sends each request to the test and answers what
  # `answer` says.
  defp client(answer) do
    test = self()

    transport = fn method, url, headers, body, _timeout ->
      request = %{method: method, url: URI.parse(url), headers: Map.new(headers), body: body}
      send(test, {:request, request})
      {status, payload, extra} = answer.(request)
      {:ok, {status, extra, if(payload, do: JSON.encode!(payload), else: "")}}
    end

    Perata.new("prk_test_key", base_url: "http://perata.test/", transport: transport)
  end

  defp product(id) do
    %{
      "id" => id,
      "name" => "Curso",
      "description" => "",
      "status" => "active",
      "created_at" => "2026-10-17T00:00:00Z"
    }
  end

  defp query(request), do: URI.decode_query(request.url.query || "")

  test "a call carries the key and unwraps the data" do
    perata = client(fn _request -> {200, %{"data" => product("prod_1")}, []} end)

    assert {:ok, %Perata.Product{id: "prod_1", status: "active"}} =
             Perata.Products.get(perata, "prod_1")

    assert_received {:request, seen}
    assert seen.method == "GET"
    assert seen.url.path == "/api/v1/products/prod_1"
    assert seen.headers["Authorization"] == "Bearer prk_test_key"
  end

  test "a write sends its body and idempotency key" do
    perata = client(fn _request -> {201, %{"data" => product("prod_1")}, []} end)

    assert {:ok, %Perata.Product{}} =
             Perata.Products.create(perata, %Perata.ProductsCreateParams{name: "Curso"},
               idempotency_key: "create-1"
             )

    assert_received {:request, seen}
    assert seen.method == "POST"
    assert seen.headers["Idempotency-Key"] == "create-1"
    assert JSON.decode!(seen.body) == %{"name" => "Curso"}
  end

  test "iterating walks every page" do
    perata =
      client(fn request ->
        page = query(request)["page"]
        items = [product("prod_#{page}")]

        {200,
         %{"data" => %{"items" => items, "pagination" => %{"total_count" => 3, "max_page" => 3}}},
         []}
      end)

    ids = perata |> Perata.Products.list_stream(limit: 1) |> Enum.map(& &1.id)
    assert ids == ["prod_1", "prod_2", "prod_3"]
    assert_received {:request, first}
    assert query(first)["limit"] == "1"
  end

  test "a refusal is a typed error" do
    perata =
      client(fn
        %{url: %URI{path: "/api/v1/customers"}} ->
          {422, %{"error" => "invalid_request", "fields" => %{"email" => ["send an e-mail"]}}, []}

        _request ->
          {429, nil, [{"retry-after", "7"}]}
      end)

    assert {:error, %Perata.Error{status: 422, code: "invalid_request", fields: fields}} =
             Perata.Customers.create(perata, name: "x", email: "x")

    assert fields["email"] == ["send an e-mail"]
    assert {:error, %Perata.Error{status: 429, retry_after: 7}} = Perata.Products.list(perata)
  end

  test "a webhook verifies only when Peráta signed it" do
    key = "0123456789abcdef0123456789abcdef"
    secret = "whsec_" <> Base.encode64(key)

    body =
      ~s({"id":"msg_1","type":"checkout_session.succeeded","timestamp":"2026-10-17T00:00:00Z","data":{"checkout_session_id":"cs_1"}})

    now = 1_800_000_000

    sign = fn at, payload ->
      mac = :crypto.mac(:hmac, :sha256, key, "msg_1.#{at}." <> payload)

      %{
        "webhook-id" => "msg_1",
        "webhook-timestamp" => Integer.to_string(at),
        "webhook-signature" => "v1,bm90LXRoaXMtb25l v1," <> Base.encode64(mac)
      }
    end

    assert {:ok, event} = Perata.verify_webhook(secret, sign.(now, body), body, now: now)
    assert event.type == "checkout_session.succeeded"
    assert event.data["checkout_session_id"] == "cs_1"

    assert {:error, %Perata.WebhookVerificationError{}} =
             Perata.verify_webhook(secret, sign.(now, body), body <> " ", now: now)

    assert {:error, %Perata.WebhookVerificationError{}} =
             Perata.verify_webhook(secret, sign.(now - 600, body), body, now: now)
  end

  test "the real HTTP sends and reads through httpc" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    server = spawn_link(fn -> serve(listener) end)
    base_url = "http://127.0.0.1:#{port}"

    assert {:ok, product} =
             "prk_test_key"
             |> Perata.new(base_url: base_url)
             |> Perata.Products.create([name: "Peráta"], idempotency_key: "create-1")

    assert {product.name, product.description, product.created_at} ==
             {"Peráta", "create-1", "POST /api/v1/products application/json"}

    assert {:ok, detached} =
             "prk_test_key"
             |> Perata.new(base_url: base_url)
             |> Perata.PaymentMethods.detach("pm 1/2")

    assert detached.id == "POST /api/v1/payment_methods/pm%201%2F2/detach -"

    assert {:error, %Perata.Error{status: 401, code: "invalid_credential", retry_after: 3}} =
             "prk_test_other" |> Perata.new(base_url: base_url) |> Perata.Products.get("prod_1")

    Process.unlink(server)
    Process.exit(server, :kill)
    :gen_tcp.close(listener)
  end

  # Answers each connection as the API would: what it was sent, wrapped in
  # data, or a 401 to another key.
  defp serve(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {head, body} = read(socket, "")
    [request_line | lines] = String.split(head, "\r\n")
    [method, path | _version] = String.split(request_line, " ")

    headers =
      Map.new(lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {status, extra, payload} = respond("#{method} #{path}", headers, body)
    encoded = JSON.encode!(payload)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n",
      extra,
      "Content-Length: #{byte_size(encoded)}\r\nConnection: close\r\n\r\n",
      encoded
    ])

    :gen_tcp.close(socket)
    serve(listener)
  end

  defp read(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length:\s*(\d+)/i, head) do
            [_, digits] -> String.to_integer(digits)
            nil -> 0
          end

        {head, read_body(socket, body, length)}

      [_partial] ->
        {:ok, more} = :gen_tcp.recv(socket, 0)
        read(socket, buffer <> more)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, more} = :gen_tcp.recv(socket, 0)
    read_body(socket, body <> more, length)
  end

  defp respond(request, headers, body) do
    cond do
      headers["authorization"] != "Bearer prk_test_key" ->
        {401, "Retry-After: 3\r\n", %{"error" => "invalid_credential"}}

      String.ends_with?(request, "/detach") ->
        {200, "",
         %{
           "data" => %{"id" => "#{request} #{headers["content-type"] || "-"}", "detached" => true}
         }}

      true ->
        {201, "",
         %{
           "data" => %{
             "id" => "prod_1",
             "name" => JSON.decode!(body)["name"],
             "description" => headers["idempotency-key"] || "",
             "status" => "active",
             "created_at" => "#{request} #{headers["content-type"]}"
           }
         }}
    end
  end
end
