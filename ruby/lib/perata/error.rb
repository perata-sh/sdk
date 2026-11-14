# frozen_string_literal: true

require "json"

module Perata
  # A request the API refused.
  #
  # +code+ is the API's: invalid_credential, forbidden, not_found,
  # invalid_request, conflict, idempotency_conflict, unsupported_media_type, body_too_large, rate_limited or
  # unavailable.
  # +message+ is the API's explanation, +fields+ says, for invalid_request,
  # what is wrong with each field, +record+ is, for the usage ingestion, the
  # position (from 1) in the batch of the event the API refused (0 for any other
  # error), and +retry_after+ is how many seconds to wait on a 429.
  class Error < StandardError
    attr_reader :status, :code, :message, :fields, :retry_after, :record

    def initialize(status, code, message = "", fields = {}, retry_after = nil, record = 0)
      @status = status
      @code = code
      @message = message
      @fields = fields
      @retry_after = retry_after
      @record = record
      super(message.empty? ? "perata: #{status} #{code}" : "perata: #{status} #{code}: #{message}")
    end

    # What Ruby prints for an error nobody rescued: the status and code too.
    def detailed_message(highlight: false, **)
      highlight ? "\e[1m#{self} (#{self.class.name})\e[m" : "#{self} (#{self.class.name})"
    end

    # The error a response with a status of 300 or more is.
    def self.from_response(status, headers, body)
      data = begin
        loaded = JSON.parse(body.to_s.empty? ? "{}" : body)
        loaded.is_a?(Hash) ? loaded : {}
      rescue JSON::ParserError
        {} # A refusal without a JSON body is still a refusal.
      end
      # Every error is the problem itself (error, message, fields). Servers from before
      # that document wrapped the usage ingestion's errors in data: still read.
      data = data["data"] if !data.key?("error") && data["data"].is_a?(Hash)
      retry_after = headers["retry-after"].to_s
      new(status, data["error"].to_s, data["message"].to_s, data["fields"] || {},
          retry_after.match?(/\A\d+\z/) ? retry_after.to_i : nil, data["record"].is_a?(Integer) ? data["record"] : 0)
    end
  end
end
