# frozen_string_literal: true

class TradeRepublicAccount::HoldingsProcessor
  include TradeRepublicAccount::DataHelpers

  def initialize(trade_republic_account)
    @trade_republic_account = trade_republic_account
  end

  def process
    return unless account.present?

    positions = Array(@trade_republic_account.raw_holdings_payload)
    return if positions.empty?

    Rails.logger.info "TradeRepublicAccount::HoldingsProcessor - Processing #{positions.size} positions"

    positions.each_with_index do |position, idx|
      process_position(position.respond_to?(:with_indifferent_access) ? position.with_indifferent_access : position)
    rescue => e
      Rails.logger.error "TradeRepublicAccount::HoldingsProcessor - Failed to process position #{idx + 1}: #{e.class} - #{e.message}"
    end
  end

  private

    def account
      @trade_republic_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_position(data)
      isin = data[:isin] || data[:instrument_id] || data[:ticker]
      return if isin.blank?

      security = resolve_security(isin, data)
      return unless security

      quantity = parse_decimal(data[:quantity] || data[:net_size] || data[:units])
      return if quantity.nil? || quantity <= 0

      average_buy_in = parse_decimal(data[:average_buy_in]) || parse_decimal(data[:averageBuyIn])
      # Snapshot price: prefer the live price from the sidecar, fall back to the
      # average buy-in. Ongoing valuation is handled by Sure's market-data
      # providers via the Security record (resolved by ISIN above).
      price = parse_decimal(data[:current_price]) || average_buy_in || parse_decimal(data[:price])
      return if price.nil?

      amount = quantity * price
      currency = data[:currency].presence || account.currency || "EUR"

      Rails.logger.info "TradeRepublicAccount::HoldingsProcessor - Importing holding: #{isin} qty=#{quantity} price=#{price}"

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: Date.current,
        price: price,
        account_provider_id: @trade_republic_account.account_provider&.id,
        source: "trade_republic",
        delete_future_holdings: false
      )

      update_holding_cost_basis(security, average_buy_in) if average_buy_in.present?
    end

    def update_holding_cost_basis(security, cost_basis)
      holding = account.holdings
        .where(security: security)
        .where("cost_basis_source != 'manual' OR cost_basis_source IS NULL")
        .order(date: :desc)
        .first
      return unless holding

      value = parse_decimal(cost_basis)
      return if value.nil?

      holding.update!(cost_basis: value, cost_basis_source: "provider")
    end
end
