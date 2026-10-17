# frozen_string_literal: true

require "json"
require "openssl"

# Verifying the webhooks Peráta sends, as Standard Webhooks signs them.
module Perata
  # How far from now a webhook's timestamp may be, in seconds.
  WEBHOOK_TOLERANCE_SECONDS = 300

  # A request Peráta did not sign, or signed too long ago.
  class WebhookVerificationError < StandardError
    def initialize(message = "perata: webhook signature does not verify")
      super
    end
  end

  # What Peráta posts to an endpoint.
  class WebhookEvent < Model
    MEMBERS = %i[id type timestamp data].freeze

    # @return [String]
    attr_reader :id, :type, :timestamp
    # @return [Hash{String => String}]
    attr_reader :data

    def initialize(id:, type:, timestamp:, data:)
      @id = id
      @type = type
      @timestamp = timestamp
      @data = data
      freeze
    end
  end

  # Checks a webhook Peráta sent and answers its event.
  #
  # The signature is an HMAC-SHA256 of +{webhook-id}.{webhook-timestamp}.{body}+
  # under the key the endpoint's +whsec_+ secret encodes. Pass the body exactly
  # as it arrived, before parsing it; +headers+ is a hash of the request's
  # headers, in any case, or a Rack env.
  #
  # @return [WebhookEvent]
  # @raise [WebhookVerificationError]
  def self.verify_webhook(secret, headers, body, now: Time.now)
    key = begin
      secret.delete_prefix("whsec_").unpack1("m0")
    rescue ArgumentError
      ""
    end
    raise ArgumentError, "perata: the webhook secret is whsec_ and a base64 key" if key.empty?

    raw = body.to_s.b
    webhook_id = webhook_header(headers, "webhook-id")
    stamp = webhook_header(headers, "webhook-timestamp")
    raise WebhookVerificationError if webhook_id.empty? || !stamp.match?(/\A\d+\z/)
    raise WebhookVerificationError if (now.to_i - stamp.to_i).abs > WEBHOOK_TOLERANCE_SECONDS

    expected = OpenSSL::HMAC.digest("SHA256", key, "#{webhook_id}.#{stamp}.".b + raw)
    webhook_header(headers, "webhook-signature").split.each do |signature|
      version, encoded = signature.split(",", 2)
      next unless version == "v1" && encoded

      decoded = begin
        encoded.unpack1("m0")
      rescue ArgumentError
        next
      end
      next unless decoded.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(decoded, expected)

      event = JSON.parse(raw.force_encoding(Encoding::UTF_8))
      return WebhookEvent.new(id: event.fetch("id"), type: event.fetch("type"), timestamp: event.fetch("timestamp"),
                              data: event["data"] || {})
    end
    raise WebhookVerificationError
  end

  # A header's value, looked up in any case; a Rack env's HTTP_WEBHOOK_ID
  # names webhook-id.
  def self.webhook_header(headers, name)
    headers.each do |key, value|
      return value.to_s if key.to_s.downcase.tr("_", "-").delete_prefix("http-") == name
    end
    ""
  end
  private_class_method :webhook_header
end
