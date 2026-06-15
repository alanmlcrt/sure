# frozen_string_literal: true

module TradeRepublicItem::Provided
  extend ActiveSupport::Concern

  # Returns a Provider::TradeRepublic configured to talk to the tr-auth sidecar.
  # The sidecar handles both the WAF-protected HTTP auth and the WebSocket
  # portfolio fetch, so no session token is required to build the provider —
  # it is passed per-call.
  def trade_republic_provider
    Provider::TradeRepublic.new
  end
end
