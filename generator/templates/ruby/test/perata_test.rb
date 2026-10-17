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

  def test_a_webhook_verifies_only_when_perata_signed_it
    key = "0123456789abcdef0123456789abcdef"
    secret = "whsec_#{[key].pack("m0")}"
    body = '{"id":"msg_1","type":"checkout_session.succeeded","timestamp":"2026-10-17T00:00:00Z","data":{"checkout_session_id":"cs_1"}}'
    now = 1_800_000_000
    sign = lambda do |at, payload|
      mac = OpenSSL::HMAC.digest("SHA256", key, "msg_1.#{at}.#{payload}")
      { "webhook-id" => "msg_1", "webhook-timestamp" => at.to_s, "webhook-signature" => "v1,bm90LXRoaXMtb25l v1,#{[mac].pack("m0")}" }
    end
    event = Perata.verify_webhook(secret, sign.call(now, body), body, now: now)
    assert_equal "checkout_session.succeeded", event.type
    assert_equal "cs_1", event.data["checkout_session_id"]
    assert_raises(Perata::WebhookVerificationError) { Perata.verify_webhook(secret, sign.call(now, body), "#{body} ", now: now) }
    assert_raises(Perata::WebhookVerificationError) { Perata.verify_webhook(secret, sign.call(now - 600, body), body, now: now) }
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
