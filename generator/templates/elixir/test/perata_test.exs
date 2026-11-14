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

    Perata.new("prk_test_key", base_url: "https://perata.test/", transport: transport)
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

  test "a base URL must be https unless it is loopback" do
    for base <- [
          "https://perata.sh",
          "http://localhost:8080",
          "http://LOCALHOST",
          "http://127.0.0.1:1",
          "http://127.255.0.3",
          "http://[::1]:8080"
        ] do
      assert %Perata.Client{} = Perata.new("k", base_url: base)
    end

    for base <- [
          "http://perata.sh",
          "http://localhost.evil.test",
          "http://127.0.0.1.evil.test",
          "http://10.0.0.1",
          "ftp://localhost",
          "perata.sh",
          "",
          "http://[::2]"
        ] do
      assert_raise ArgumentError, ~r/must be https/, fn -> Perata.new("k", base_url: base) end
    end
  end

  test "a discount goes through create, get, list and delete" do
    discount = fn id -> JSON.decode!(String.replace(~S|{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}|, "__ID__", id)) end

    perata =
      client(fn request ->
        cond do
          request.method == "POST" ->
            {201, %{"data" => discount.("disc_1")}, []}

          request.method == "DELETE" ->
            {204, nil, []}

          request.url.path == "/api/v1/discounts" ->
            page = query(request)["page"]

            {200,
             %{
               "data" => %{
                 "items" => [discount.("disc_#{page}")],
                 "pagination" => %{"total_count" => 2, "max_page" => 2}
               }
             }, []}

          true ->
            {200, %{"data" => discount.("disc_1")}, []}
        end
      end)

    assert {:ok, %Perata.Discount{id: "disc_1", code: nil, product_ids: ["prod_1"]}} =
             Perata.Discounts.create(perata, %Perata.DiscountsCreateParams{
               name: "Black",
               type: "percentage",
               duration: "once",
               basis_points: 1000
             })

    assert {:ok, %Perata.Discount{name: "Black"}} = Perata.Discounts.get(perata, "disc_1")

    assert Perata.Discounts.list_stream(perata, limit: 1) |> Enum.map(& &1.id) == ["disc_1", "disc_2"]
    assert :ok = Perata.Discounts.delete(perata, "disc_1")

    requests = for _ <- 1..5, do: (assert_received {:request, seen}; "#{seen.method} #{seen.url.path}")

    assert requests == [
             "POST /api/v1/discounts",
             "GET /api/v1/discounts/disc_1",
             "GET /api/v1/discounts",
             "GET /api/v1/discounts",
             "DELETE /api/v1/discounts/disc_1"
           ]
  end

  test "a free-form value decodes nested" do
    state = JSON.decode!(~S|{"id":"cus_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}|)
    perata = client(fn _request -> {200, %{"data" => state}, []} end)

    assert {:ok, %Perata.CustomerState{granted_benefits: [grant]}} =
             Perata.Customers.get_state(perata, "cus_1")

    assert grant.benefit_metadata == %{
             "flags" => %{"beta" => true, "limits" => %{"seats" => 5, "tiers" => ["a", 2, nil, 1.5]}}
           }

    assert grant.properties == %{"links" => [%{"url" => "https://example.com", "expires" => nil}]}
  end

  test "a POST without a key is sent with its own, a GET with none" do
    perata = client(fn _request -> {201, %{"data" => product("prod_1")}, []} end)
    params = %Perata.ProductsCreateParams{name: "Curso"}

    {:ok, _} = Perata.Products.create(perata, params)
    {:ok, _} = Perata.Products.create(perata, params)
    {:ok, _} = Perata.Products.create(perata, params, idempotency_key: "mine")
    {:ok, _} = Perata.Products.get(perata, "prod_1")

    keys =
      for _ <- 1..4 do
        assert_received {:request, seen}
        seen.headers["Idempotency-Key"]
      end

    uuid = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    [first, second, third, fourth] = keys
    assert first =~ uuid
    assert second =~ uuid
    assert first != second
    assert third == "mine"
    assert fourth == nil
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

  test "usage ingestion carries the source credential and its events" do
    test = self()

    transport = fn method, url, headers, body, _timeout ->
      send(test, {:request, %{method: method, url: URI.parse(url), headers: Map.new(headers), body: body}})
      {:ok, {200, [], JSON.encode!(%{"data" => %{"created" => 1, "replayed" => 0}})}}
    end

    usage = Perata.new("pus_live_source", base_url: "https://perata.test/", transport: transport)

    event = %Perata.UsageIngestEvent{
      customer_id: "cus_1",
      external_event_id: "req-1",
      input_tokens: "1200",
      output_tokens: "300",
      cached_tokens: "0",
      occurred_at: "2026-11-13T12:00:00Z",
      _cost: %Perata.UsageIngestEventCost{amount: "1.250000", currency: "brl"}
    }

    assert {:ok, %Perata.UsageIngestReceipt{created: 1, replayed: 0}} =
             Perata.Usage.ingest(usage, %{events: [event]})

    assert_received {:request, seen}
    assert seen.method == "POST"
    assert seen.url.path == "/api/v1/usage/token-events"
    assert seen.headers["Authorization"] == "Bearer pus_live_source"
    assert %{"events" => [sent]} = JSON.decode!(seen.body)
    assert sent["customer_id"] == "cus_1"
    assert sent["_cost"] == %{"amount" => "1.250000", "currency" => "brl"}
    refute Map.has_key?(sent, "_llm")
    refute Map.has_key?(sent, "parent_id")
  end

  test "usage ingestion errors are the flat error document" do
    event = %Perata.UsageIngestEvent{
      customer_id: "cus_1",
      external_event_id: "req-1",
      input_tokens: "1",
      output_tokens: "0",
      cached_tokens: "0",
      occurred_at: "2026-11-13T12:00:00Z"
    }

    cases = [
      {401, %{"error" => "invalid_credential"}, "invalid_credential", 0, ""},
      {409, %{"error" => "conflict", "record" => 2, "message" => "conflict"}, "conflict", 2,
       "conflict"},
      {422,
       %{
         "error" => "invalid_request",
         "record" => 3,
         "message" => "validation failed: customer_id",
         "fields" => %{"customer_id" => ["unknown"]}
       }, "invalid_request", 3, "validation failed: customer_id"},
      {400, %{"error" => "invalid_request", "message" => "malformed JSON"}, "invalid_request", 0,
       "malformed JSON"},
      {415, %{"error" => "unsupported_media_type"}, "unsupported_media_type", 0, ""},
      {500, %{"error" => "unavailable"}, "unavailable", 0, ""}
    ]

    for {status, problem, code, record, message} <- cases do
      usage = client(fn _request -> {status, problem, []} end)

      assert {:error, %Perata.Error{status: ^status, code: ^code, record: ^record, message: ^message} = error} =
               Perata.Usage.ingest(usage, %{events: [event]})

      if status == 422, do: assert(error.fields == %{"customer_id" => ["unknown"]})
    end
  end

  test "an error wrapped in data by an older server is still read" do
    event = %Perata.UsageIngestEvent{
      customer_id: "cus_1",
      external_event_id: "req-1",
      input_tokens: "1",
      output_tokens: "0",
      cached_tokens: "0",
      occurred_at: "2026-11-13T12:00:00Z"
    }

    usage =
      client(fn _request ->
        {409, %{"data" => %{"error" => "event_conflict", "record" => 2, "message" => "conflict"}}, []}
      end)

    assert {:error, %Perata.Error{status: 409, code: "event_conflict", record: 2}} =
             Perata.Usage.ingest(usage, %{events: [event]})
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

  # The webhook vectors every SDK checks: Standard Webhooks' own example, and
  # Peráta events signed under two secrets, as while one is rotated.
  @reference_secret "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  @old_secret "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM="
  @new_secret "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM="
  @order_paid ~s({"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}})
  @usage_recorded ~s({"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}})
  @payout_sent ~s({"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}})
  @signed_at 1_792_670_400

  defp webhook_headers(id, at, signature) do
    [
      {"Webhook-Id", id},
      {"webhook-timestamp", Integer.to_string(at)},
      {"webhook-signature", signature}
    ]
  end

  test "the Standard Webhooks vector verifies" do
    body = ~s({"test": 2432232314})

    headers =
      webhook_headers(
        "msg_p5jXN8AQM9LWM0D4loKWxJek",
        1_614_265_330,
        "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
      )

    assert :ok =
             Perata.verify_webhook_signature(@reference_secret, headers, body, now: 1_614_265_330)

    for {secret, payload, now} <- [
          {@reference_secret, body <> " ", 1_614_265_330},
          {@reference_secret, body, 1_614_265_330 + 301},
          {@new_secret, body, 1_614_265_330}
        ] do
      assert {:error, %Perata.WebhookVerificationError{}} =
               Perata.verify_webhook_signature(secret, headers, payload, now: now)
    end
  end

  test "a timestamp that is not plain digits is refused" do
    for {stamp, signature} <- [
          {"+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8="},
          {"²", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="},
          {"", "x"},
          {"1_6", "x"}
        ] do
      headers = [
        {"Webhook-Id", "msg_p5jXN8AQM9LWM0D4loKWxJek"},
        {"webhook-timestamp", stamp},
        {"webhook-signature", "v1," <> signature}
      ]

      assert {:error, %Perata.WebhookVerificationError{}} =
               Perata.verify_webhook_signature(@reference_secret, headers, ~s({"test": 2432232314}),
                 now: 1_614_265_330
               )
    end
  end

  test "a webhook answers its typed event" do
    now = @signed_at + 120

    headers =
      webhook_headers(
        "msg_2",
        @signed_at,
        "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak="
      )

    for secret <- [@new_secret, @old_secret] do
      assert {:ok, %Perata.OrderWebhookEvent{type: "order.paid", data: %Perata.Order{} = order}} =
               Perata.verify_webhook(secret, headers, @order_paid, now: now)

      assert {order.id, order.installments, order.installment_interest_cents} == {"ord_1", 3, 360}
    end

    assert {:error, %Perata.WebhookVerificationError{}} =
             Perata.verify_webhook(@reference_secret, headers, @order_paid, now: now)

    usage_headers =
      webhook_headers("msg_3", @signed_at, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=")

    assert {:ok, %Perata.IdentifiersWebhookEvent{id: "msg_3", data: %{"merchant_id" => "mer_1"}}} =
             Perata.verify_webhook(@new_secret, usage_headers, @usage_recorded, now: now)

    unknown_headers =
      webhook_headers("msg_4", @signed_at, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=")

    assert {:ok, %Perata.UnknownWebhookEvent{type: "payout.sent", data: data}} =
             Perata.verify_webhook(@new_secret, unknown_headers, @payout_sent, now: now)

    assert data == %{"payout_id" => "po_1", "amount_cents" => 5000}
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
