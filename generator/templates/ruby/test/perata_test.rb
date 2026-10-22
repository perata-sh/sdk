# frozen_string_literal: true

# Peráta's Ruby SDK tests, with nothing to install: ruby -Ilib -Itest test/perata_test.rb

require "minitest/autorun"
require "json"
require "openssl"
require "socket"
require "uri"
require "perata"

class PerataTest < Minitest::Test
  # Records each request and answers what the test says.
  class Recorder
    attr_reader :seen

    def initialize(&answer)
      @answer = answer
      @seen = []
    end

    def call(method, url, headers, body, _timeout)
      request = { method: method, url: URI(url), headers: headers, body: body }
      @seen << request
      status, payload, extra = @answer.call(request)
      [status, extra, payload.nil? ? "" : JSON.generate(payload)]
    end
  end

  def client(&answer)
    recorder = Recorder.new(&answer)
    [Perata::Client.new("prk_test_key", base_url: "http://perata.test/", transport: recorder), recorder]
  end

  def product(id)
    { "id" => id, "name" => "Curso", "description" => "", "status" => "active", "created_at" => "2026-10-17T00:00:00Z" }
  end

  def query(request)
    URI.decode_www_form(request[:url].query.to_s).to_h
  end

  def test_a_call_carries_the_key_and_unwraps_the_data
    perata, recorder = client { [200, { "data" => product("prod_1") }, {}] }
    got = perata.products.get("prod_1")
    assert_equal "prod_1", got.id
    assert_equal "active", got.status
    seen = recorder.seen.first
    assert_equal "GET", seen[:method]
    assert_equal "/api/v1/products/prod_1", seen[:url].path
    assert_equal "Bearer prk_test_key", seen[:headers]["Authorization"]
  end

  def test_a_write_sends_its_body_and_idempotency_key
    perata, recorder = client { [201, { "data" => product("prod_1") }, {}] }
    perata.products.create(Perata::ProductsCreateParams.new(name: "Curso"), idempotency_key: "create-1")
    seen = recorder.seen.first
    assert_equal "POST", seen[:method]
    assert_equal "create-1", seen[:headers]["Idempotency-Key"]
    assert_equal({ "name" => "Curso" }, JSON.parse(seen[:body]))
  end

  def test_iterating_walks_every_page
    perata, recorder = client do |request|
      page = query(request)["page"]
      [200, { "data" => { "items" => [product("prod_#{page}")], "pagination" => { "total_count" => 3, "max_page" => 3 } } }, {}]
    end
    assert_equal %w[prod_1 prod_2 prod_3], perata.products.list_iter(limit: 1).map(&:id)
    assert_equal "1", query(recorder.seen.first)["limit"]
  end

  def test_a_refusal_is_a_typed_error
    perata, = client do |request|
      if request[:url].path == "/api/v1/customers"
        [422, { "error" => "invalid_request", "fields" => { "email" => ["send an e-mail"] } }, {}]
      else
        [429, nil, { "retry-after" => "7" }]
      end
    end
    refused = assert_raises(Perata::Error) { perata.customers.create({ name: "x", email: "x" }) }
    assert_equal [422, "invalid_request"], [refused.status, refused.code]
    assert_equal ["send an e-mail"], refused.fields["email"]
    limited = assert_raises(Perata::Error) { perata.products.list }
    assert_equal [429, 7], [limited.status, limited.retry_after]
  end

  # The webhook vectors every SDK checks: Standard Webhooks' own example, and
  # Peráta events signed under two secrets, as while one is rotated.
  REFERENCE_SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  OLD_SECRET = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM="
  NEW_SECRET = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM="
  ORDER_PAID = '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}'
  USAGE_RECORDED = '{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}'
  PAYOUT_SENT = '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}'
  SIGNED_AT = 1_792_670_400

  def webhook_headers(id, at, signature)
    { "Webhook-Id" => id, "webhook-timestamp" => at.to_s, "webhook-signature" => signature }
  end

  def test_the_standard_webhooks_vector_verifies
    body = '{"test": 2432232314}'
    headers = webhook_headers("msg_p5jXN8AQM9LWM0D4loKWxJek", 1_614_265_330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
    at = Time.at(1_614_265_330)
    assert_nil Perata.verify_webhook_signature(REFERENCE_SECRET, headers, body, now: at)
    [[REFERENCE_SECRET, "#{body} ", at], [REFERENCE_SECRET, body, at + 301], [NEW_SECRET, body, at]].each do |secret, payload, now|
      assert_raises(Perata::WebhookVerificationError) { Perata.verify_webhook_signature(secret, headers, payload, now: now) }
    end
  end

  def test_a_webhook_answers_its_typed_event
    now = Time.at(SIGNED_AT + 120)
    headers = webhook_headers("msg_2", SIGNED_AT, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=")
    [NEW_SECRET, OLD_SECRET].each do |secret|
      event = Perata.verify_webhook(secret, headers, ORDER_PAID, now: now)
      assert_instance_of Perata::OrderWebhookEvent, event
      assert_equal ["order.paid", "ord_1", 3, 360], [event.type, event.data.id, event.data.installments, event.data.installment_interest_cents]
    end
    assert_raises(Perata::WebhookVerificationError) { Perata.verify_webhook(REFERENCE_SECRET, headers, ORDER_PAID, now: now) }
    usage = Perata.verify_webhook(NEW_SECRET, webhook_headers("msg_3", SIGNED_AT, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), USAGE_RECORDED, now: now)
    assert_instance_of Perata::IdentifiersWebhookEvent, usage
    assert_equal %w[msg_3 mer_1], [usage.id, usage.data["merchant_id"]]
    unknown = Perata.verify_webhook(NEW_SECRET, webhook_headers("msg_4", SIGNED_AT, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), PAYOUT_SENT, now: now)
    assert_instance_of Perata::UnknownWebhookEvent, unknown
    assert_equal ["payout.sent", { "payout_id" => "po_1", "amount_cents" => 5000 }], [unknown.type, unknown.data]
  end

  def test_the_real_http_sends_and_reads_through_net_http
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new { loop { answer(server.accept) } }
    base_url = "http://127.0.0.1:#{server.addr[1]}"
    product = Perata::Client.new("prk_test_key", base_url: base_url).products.create({ name: "Peráta" }, idempotency_key: "create-1")
    assert_equal ["Peráta", "create-1", "POST /api/v1/products application/json"], [product.name, product.description, product.created_at]
    detached = Perata::Client.new("prk_test_key", base_url: base_url).payment_methods.detach("pm 1/2")
    assert_equal "POST /api/v1/payment_methods/pm%201%2F2/detach -", detached.id
    refused = assert_raises(Perata::Error) { Perata::Client.new("prk_test_other", base_url: base_url).products.get("prod_1") }
    assert_equal [401, "invalid_credential", 3], [refused.status, refused.code, refused.retry_after]
  ensure
    thread&.kill
    server&.close
  end

  private

  # Answers one connection as the API would: what it was sent, wrapped in
  # data, or a 401 to another key.
  def answer(socket)
    request_line = socket.gets.to_s
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(headers["content-length"].to_i).to_s.force_encoding(Encoding::UTF_8)
    status, extra, payload = respond(request_line.split[0, 2].join(" "), headers, body)
    encoded = JSON.generate(payload).b
    socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n#{extra}Content-Length: #{encoded.bytesize}\r\nConnection: close\r\n\r\n")
    socket.write(encoded)
  ensure
    socket.close
  end

  def respond(request, headers, body)
    return [401, "Retry-After: 3\r\n", { "error" => "invalid_credential" }] if headers["authorization"] != "Bearer prk_test_key"

    name = body.empty? ? "" : JSON.parse(body)["name"]
    if request.end_with?("/detach")
      return [200, "", { "data" => { "id" => "#{request} #{headers["content-type"] || "-"}", "detached" => true } }]
    end

    [201, "", { "data" => { "id" => "prod_1", "name" => name, "description" => headers["idempotency-key"].to_s, "status" => "active",
                            "created_at" => "#{request} #{headers["content-type"]}" } }]
  end
end
