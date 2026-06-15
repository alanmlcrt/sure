# frozen_string_literal: true

# Client for the `tr-auth` sidecar (services/tr-auth), which encapsulates the
# two pieces of Trade Republic integration that cannot be done from plain Ruby:
#
#   1. The WAF-protected HTTP auth flow (phone + PIN -> 2FA -> session tokens),
#      solved with a headless browser to obtain the AWS WAF token.
#   2. The reverse-engineered WebSocket portfolio fetch (cash + positions).
#
# Keeping both in the sidecar means Sure stays dependency-free (no WebSocket
# gem) and just speaks plain JSON/HTTP to it.
class Provider::TradeRepublic
  include HTTParty

  headers "User-Agent" => "Sure Finance Trade Republic Client", "Content-Type" => "application/json"
  default_options.merge!(timeout: 90)

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  # Raised when the stored session (and refresh) tokens are no longer valid.
  class SessionExpiredError < Error; end

  DEFAULT_BASE_URL = "http://tr-auth:8001"

  def initialize(base_url: nil)
    @base_url = base_url || ENV["TR_AUTH_URL"].presence || DEFAULT_BASE_URL
  end

  # Step 1: send phone + PIN. Trade Republic dispatches a 2FA code.
  # Returns the processId used to complete the login. Credentials are NOT stored.
  def initiate_auth(phone_number:, pin:)
    response = post_json("/initiate", { phoneNumber: phone_number, pin: pin })
    process_id = response["processId"]
    raise AuthenticationError, "Trade Republic did not return a valid session. Please try again." if process_id.blank?

    process_id
  end

  # Step 2: exchange the 2FA code for session + refresh tokens.
  def complete_auth(process_id:, tan:)
    response = post_json("/complete", { processId: process_id, tan: tan })
    session_token = response["sessionToken"]
    raise AuthenticationError, "The verification code is invalid or has expired. Please request a new one." if session_token.blank?

    { session_token: session_token, refresh_token: response["refreshToken"] }
  end

  # Refresh the session using the stored refresh token (no 2FA needed).
  def refresh_session(refresh_token:)
    response = post_json("/refresh", { refreshToken: refresh_token })
    session_token = response["sessionToken"]
    raise SessionExpiredError, "Trade Republic session could not be refreshed." if session_token.blank?

    { session_token: session_token, refresh_token: response["refreshToken"] }
  end

  # Fetch the current portfolio over the TR WebSocket (via the sidecar).
  # Returns a normalised hash:
  #   {
  #     cash:       { balance: <BigDecimal>, currency: "EUR" },
  #     securities: { value: <BigDecimal>, currency: "EUR", positions: [
  #       { isin:, name:, quantity:, average_buy_in:, current_price: }, ...
  #     ] }
  #   }
  def fetch_portfolio(session_token:)
    response = post_json("/portfolio", { sessionToken: session_token })

    cash = response["cash"] || {}
    securities = response["securities"] || {}

    {
      cash: {
        balance: cash["balance"],
        currency: cash["currency"] || "EUR"
      },
      securities: {
        value: securities["value"],
        currency: securities["currency"] || "EUR",
        positions: Array(securities["positions"]).map { |p| normalize_position(p) }
      }
    }
  end

  private

    attr_reader :base_url

    def normalize_position(position)
      {
        isin: position["isin"],
        name: position["name"],
        quantity: position["quantity"],
        average_buy_in: position["averageBuyIn"] || position["average_buy_in"],
        current_price: position["currentPrice"] || position["current_price"],
        currency: position["currency"]
      }
    end

    def post_json(path, body)
      response = self.class.post(
        "#{base_url}#{path}",
        body: body.to_json
      )
      handle_response(response, path)
    rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "Could not reach the Trade Republic service (#{e.class}). Is the tr-auth sidecar running?"
    end

    def handle_response(response, path)
      case response.code
      when 200, 201
        parse_body(response)
      when 401, 403
        # The sidecar surfaces an expired/refused session for /refresh and
        # /portfolio; treat those as a recoverable session-expiry signal.
        raise SessionExpiredError, error_detail(response, "Trade Republic session expired.")
      when 400, 422
        raise AuthenticationError, error_detail(response, "Trade Republic rejected the request.")
      else
        # /refresh on the sidecar returns the literal "SESSION_EXPIRED" detail.
        detail = error_detail(response, "Trade Republic service error (#{response.code}).")
        raise SessionExpiredError, detail if detail.to_s.include?("SESSION_EXPIRED")

        raise Error, detail
      end
    end

    def parse_body(response)
      return {} if response.body.blank?

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "Invalid response from Trade Republic service: #{e.message}"
    end

    def error_detail(response, fallback)
      body = parse_body(response) rescue {}
      body.is_a?(Hash) ? (body["detail"] || body["error"] || fallback) : fallback
    end
end
