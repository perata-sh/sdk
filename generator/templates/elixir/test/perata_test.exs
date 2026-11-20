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
      "showcase_id" => "shw_1",
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

  defp session(client_secret) do
    %{
      "id" => "pcl_1",
      "url" => "https://perata.sh/pagamento/pcl_1",
      "product_id" => "prod_1",
      "price_id" => "price_1",
      "status" => "active",
      "label" => "",
      "quantity" => 1,
      "success_url" => "https://loja.example/obrigado",
      "cancel_url" => "",
      "expires_at" => nil,
      "created_at" => "2026-11-16T12:00:00Z",
      "session_id" => "cs_1",
      "client_secret" => client_secret,
      "client_secret_expires_at" => "2026-11-16T12:30:00Z",
      "status_key" => "sk_1",
      "amount_cents" => nil,
      "items" => [],
      "metadata" => %{},
      "client_reference_id" => "",
      "discount_id" => "",
      "showcase_id" => "shw_1",
      "subscription_start_at" => nil
    }
  end

  test "a checkout session hands back the client secret for the browser" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    perata =
      client(fn _request ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {201, %{"data" => session("cs_secret_1")}, []}
          _ -> {201, %{"data" => session("")}, [{"idempotent-replayed", "true"}]}
        end
      end)

    params = %{
      product_id: "prod_1",
      price_id: "price_1",
      success_url: "https://loja.example/obrigado"
    }

    assert {:ok, checkout} = Perata.Checkouts.create(perata, params, idempotency_key: "pedido-1")
    assert checkout.client_secret == "cs_secret_1"
    assert checkout.session_id == "cs_1"
    assert checkout.status_key == "sk_1"
    assert checkout.client_secret_expires_at == "2026-11-16T12:30:00Z"
    assert checkout.url == "https://perata.sh/pagamento/pcl_1"
    assert checkout.expires_at == nil

    assert_received {:request, seen}
    assert seen.method == "POST"
    assert seen.url.path == "/api/v1/checkouts"
    assert seen.headers["Idempotency-Key"] == "pedido-1"

    assert JSON.decode!(seen.body) == %{
             "product_id" => "prod_1",
             "price_id" => "price_1",
             "success_url" => "https://loja.example/obrigado"
           }

    assert {:ok, again} = Perata.Checkouts.create(perata, params, idempotency_key: "pedido-1")
    assert again.client_secret == ""
    assert again.session_id == "cs_1"
  end

  test "a model that may be null decodes both ways" do
    pix = %{"copia_e_cola" => "000201", "qr_code_svg" => "<svg/>", "expires_at" => nil}

    payment = %{
      "id" => "pay_1",
      "method" => "pix",
      "state" => "pending",
      "unresolved" => false,
      "card_brand" => "",
      "card_kind" => "",
      "installments" => 1,
      "pix" => pix,
      "boleto" => nil
    }

    got = Perata.CheckoutClientPayment.from_map(payment)
    assert got.boleto == nil
    assert got.pix.copia_e_cola == "000201"
    assert got.pix.expires_at == nil
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
    state = JSON.decode!(~S|{"id":"cus_1","showcase_id":"shw_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}|)
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

  test "a metadata filter is sent as one pair a key, the keys sorted and escaped" do
    perata = client(fn _request -> {200, %{"data" => %{"items" => [], "pagination" => %{"total_count" => 0, "max_page" => 1}}}, []} end)
    metadata = %{"pedido" => "123", "camera id" => "a/b"}

    assert {:ok, _page} =
             Perata.Orders.list(perata, client_reference_id: "pedido-1", metadata: metadata)

    assert_received {:request, first}

    assert first.url.query ==
             "client_reference_id=pedido-1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123"

    assert query(first)["metadata[camera id]"] == "a/b"
    assert [] = perata |> Perata.Checkouts.list_stream(limit: 1, metadata: metadata) |> Enum.to_list()
    assert_received {:request, walked}

    assert walked.url.query ==
             "page=1&limit=1&metadata%5Bcamera+id%5D=a%2Fb&metadata%5Bpedido%5D=123"
  end

  test "customers are listed by e-mail" do
    perata = client(fn _request -> {200, %{"data" => %{"items" => [], "pagination" => %{"total_count" => 0, "max_page" => 1}}}, []} end)

    assert {:ok, _page} = Perata.Customers.list(perata, email: "ana@example.com")
    assert_received {:request, seen}
    assert seen.url.path == "/api/v1/customers"
    assert seen.url.query == "email=ana%40example.com"
  end

  # A graduated price goes out with its tiers and without the fixed amount, and a
  # subscription reads back the quantity it bills and the order reference it
  # came from; amount_cents is the cycle's total for that quantity.
  test "a graduated price carries its tiers and a subscription its quantity" do
    tiers = [%{"up_to" => 1, "unit_amount_cents" => 25_000}, %{"up_to" => nil, "unit_amount_cents" => 15_000}]

    price = %{
      "id" => "price_1", "product_id" => "prod_1", "type" => "recurring", "interval" => "month",
      "interval_count" => 1, "currency" => "BRL", "status" => "active", "amount_cents" => 0,
      "pricing_model" => "graduated", "unit_amount_cents" => nil, "unit_label" => "câmera",
      "unit_label_plural" => "câmeras", "tiers" => tiers
    }

    subscription = %{
      "id" => "sub_1", "amount_cents" => 55_000, "cancel_at_period_end" => false,
      "client_reference_id" => "pedido-9", "currency" => "BRL",
      "current_period_end" => "2026-12-20T00:00:00Z", "current_period_start" => "2026-11-20T00:00:00Z",
      "customer_id" => "cus_1", "interval" => "month", "metadata" => %{"camera" => "c1"},
      "price_id" => "price_1", "product_id" => "prod_1", "quantity" => 3, "showcase_id" => "shw_1",
      "status" => "active", "suspended_at" => nil, "suspension_reason" => nil, "trial_end" => nil,
      "trial_start" => nil
    }

    perata =
      client(fn
        %{method: "POST"} -> {201, %{"data" => price}, []}
        _request -> {200, %{"data" => subscription}, []}
      end)

    assert {:ok, %Perata.Price{tiers: [first, last]} = created} =
             Perata.Prices.create(perata,
               product_id: "prod_1",
               type: "recurring",
               interval: "month",
               pricing_model: "graduated",
               tiers: [
                 %Perata.PricesCreateTier{up_to: 1, unit_amount_cents: 25_000},
                 %Perata.PricesCreateTier{unit_amount_cents: 15_000}
               ],
               unit_label: "câmera",
               unit_label_plural: "câmeras"
             )

    assert_received {:request, seen}
    assert seen.url.path == "/api/v1/prices"
    sent = JSON.decode!(seen.body)
    assert sent["pricing_model"] == "graduated"
    assert sent["tiers"] == [%{"up_to" => 1, "unit_amount_cents" => 25_000}, %{"unit_amount_cents" => 15_000}]
    refute Map.has_key?(sent, "amount_cents")
    assert {created.pricing_model, created.amount_cents, created.unit_amount_cents} == {"graduated", 0, nil}
    assert {first.up_to, first.unit_amount_cents} == {1, 25_000}
    assert {last.up_to, last.unit_amount_cents} == {nil, 15_000}

    assert {:ok, %Perata.Subscription{quantity: 3, amount_cents: 55_000, client_reference_id: "pedido-9"}} =
             Perata.Subscriptions.get(perata, "sub_1")

    assert_received {:request, seen}
    assert seen.url.path == "/api/v1/subscriptions/sub_1"
  end

  # A checkout adds the buyer's remaining days to the first period, an extension
  # goes out alone (no price_id), and the sale reads back what it took: the
  # discount on the order and on the subscription, and the change scheduled for
  # the next period.
  test "a first period extension and the discounts the sale reads back" do
    answers = %{
      "POST /api/v1/checkouts" => {201, ~S'{"data":{"id":"pcl_1","showcase_id":"x","url":"x","product_id":"prod_1","price_id":"price_1","status":"active","label":"x","quantity":0,"amount_cents":null,"items":[],"metadata":{},"client_reference_id":"x","success_url":"x","cancel_url":"x","expires_at":null,"subscription_start_at":null,"discount_id":"disc_1","first_period_extra_days":30,"created_at":"2026-11-20T12:00:00Z","session_id":"cs_1","client_secret":"cs_secret_1","client_secret_expires_at":"2026-11-20T12:00:00Z","status_key":"x"}}'},
      "PATCH /api/v1/subscriptions/sub_1" => {200, ~S'{"data":{"id":"sub_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":{"price_id":"price_2","quantity":5,"amount_cents":90000,"effective_at":"2026-12-20T03:00:00Z"},"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":"disc_1","discount_ends_at":"2027-03-01T03:00:00Z","first_period_extra_days":30}}'},
      "GET /api/v1/subscriptions/sub_2" => {200, ~S'{"data":{"id":"sub_2","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","status":"active","amount_cents":0,"quantity":0,"currency":"BRL","interval":"x","current_period_start":"2026-11-20T12:00:00Z","current_period_end":"2026-11-20T12:00:00Z","cancel_at_period_end":false,"pending_update":null,"suspended_at":null,"suspension_reason":null,"trial_start":null,"trial_end":null,"metadata":{},"client_reference_id":"x","discount_id":null,"discount_ends_at":null,"first_period_extra_days":null}}'},
      "GET /api/v1/orders/ord_1" => {200, ~S'{"data":{"id":"ord_1","showcase_id":"x","customer_id":"x","product_id":"x","price_id":"x","amount_cents":9000,"currency":"BRL","status":"open","paid_at":null,"order_status":null,"refunded_amount_cents":0,"installments":0,"installment_interest_cents":0,"items":[],"metadata":{},"client_reference_id":"x","subscription_id":null,"cycle_sequence":null,"period_start":null,"period_end":null,"discount_id":"disc_1","discount_code":"BEMVINDO","subtotal_cents":10000,"discount_cents":1000}}'},
      "GET /api/v1/prices/price_1" => {200, ~S'{"data":{"id":"price_1","product_id":"prod_1","currency":"BRL","amount_cents":9000,"type":"one_time","interval":"none","interval_count":0,"pricing_model":"fixed","unit_amount_cents":null,"tiers":[],"unit_label":"x","unit_label_plural":"x","minimum_units":null,"maximum_units":null,"status":"archived"}}'}
    }

    perata =
      client(fn request ->
        {status, body} = Map.fetch!(answers, "#{request.method} #{request.url.path}")
        {status, JSON.decode!(body), []}
      end)

    assert {:ok, %Perata.CheckoutCreated{first_period_extra_days: 30, discount_id: "disc_1"}} =
             Perata.Checkouts.create(perata, product_id: "prod_1", price_id: "price_1", first_period_extra_days: 30)

    assert_received {:request, seen}
    assert JSON.decode!(seen.body)["first_period_extra_days"] == 30

    assert {:ok, %Perata.Subscription{} = subscription} =
             Perata.Subscriptions.update(perata, "sub_1", extend_current_period_days: 15)

    assert_received {:request, seen}
    sent = JSON.decode!(seen.body)
    assert {seen.method, sent["extend_current_period_days"]} == {"PATCH", 15}
    refute Map.has_key?(sent, "price_id")

    assert {subscription.first_period_extra_days, subscription.discount_id, subscription.discount_ends_at} ==
             {30, "disc_1", "2027-03-01T03:00:00Z"}

    assert %Perata.SubscriptionPendingUpdate{price_id: "price_2", quantity: 5, amount_cents: 90_000, effective_at: "2026-12-20T03:00:00Z"} =
             subscription.pending_update

    assert {:ok, %Perata.Subscription{pending_update: nil, first_period_extra_days: nil, discount_id: nil}} =
             Perata.Subscriptions.get(perata, "sub_2")

    assert {:ok, %Perata.Order{subtotal_cents: 10_000, discount_cents: 1000, discount_id: "disc_1", discount_code: "BEMVINDO"}} =
             Perata.Orders.get(perata, "ord_1")

    assert {:ok, %Perata.Price{status: "archived"}} = Perata.Prices.get(perata, "price_1")
    assert_received {:request, _sub_2}
    assert_received {:request, _order}
    assert_received {:request, seen}
    assert seen.url.path == "/api/v1/prices/price_1"
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
  @order_paid ~s({"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}})
  @usage_recorded ~s({"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}})
  @payout_sent ~s({"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}})
  @order_paid_live ~s({"id":"msg_5","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","environment":"live","showcase_id":"shw_1","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","order_status":"paid","refunded_amount_cents":0,"refund_id":null,"refund_amount_cents":null,"installments":3,"installment_interest_cents":360,"items":[],"metadata":{},"client_reference_id":"","showcase_id":"shw_1","subtotal_cents":12000,"discount_cents":0,"discount_id":null,"discount_code":null}})
  @payout_sent_test ~s({"id":"msg_6","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","environment":"test","data":{"payout_id":"po_1","amount_cents":5000}})
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

  test "a webhook carries the environment it happened in" do
    now = @signed_at + 120

    for {id, signature, body} <- [
          {"msg_2", "v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs=", @order_paid},
          {"msg_3", "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=", @usage_recorded},
          {"msg_4", "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=", @payout_sent}
        ] do
      assert {:ok, %{environment: "", showcase_id: ""}} =
               Perata.verify_webhook(@new_secret, webhook_headers(id, @signed_at, signature), body,
                 now: now
               )
    end

    assert {:ok, %Perata.OrderWebhookEvent{environment: "live", showcase_id: "shw_1", data: %Perata.WebhookOrder{showcase_id: "shw_1"}}} =
             Perata.verify_webhook(
               @new_secret,
               webhook_headers("msg_5", @signed_at, "v1,vJOO2qPe9Vzlr42VPwCuIO+a6Sg8ZVfl9z4WuLJItwg="),
               @order_paid_live,
               now: now
             )

    assert {:ok, %Perata.UnknownWebhookEvent{environment: "test", showcase_id: ""}} =
             Perata.verify_webhook(
               @new_secret,
               webhook_headers("msg_6", @signed_at, "v1,6He63m1rUlB789sgtRAHqex4wyKkzAwdHt6uRsp8YQM="),
               @payout_sent_test,
               now: now
             )
  end

  test "a webhook answers its typed event" do
    now = @signed_at + 120

    headers =
      webhook_headers(
        "msg_2",
        @signed_at,
        "v1,wR5lfpym2P4TnG65MaTym1j5wWmRCtcygqTrQNICOEQ= v1,BLGtoe01YFYZHfU7Hcj8qvYNfluZvoTrRaAjcfB8JSs="
      )

    for secret <- [@new_secret, @old_secret] do
      assert {:ok, %Perata.OrderWebhookEvent{type: "order.paid", data: %Perata.WebhookOrder{} = order}} =
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
             "showcase_id" => "shw_1",
             "created_at" => "#{request} #{headers["content-type"]}"
           }
         }}
    end
  end
end
