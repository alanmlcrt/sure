# frozen_string_literal: true

class TradeRepublicItem::Importer
  CASH_EXTERNAL_ID       = "tr_cash"
  SECURITIES_EXTERNAL_ID = "tr_securities"

  attr_reader :trade_republic_item, :trade_republic_provider, :sync

  def initialize(trade_republic_item, trade_republic_provider:, sync: nil)
    @trade_republic_item = trade_republic_item
    @trade_republic_provider = trade_republic_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "TradeRepublicItem::Importer - Starting import for item #{trade_republic_item.id}"

    unless trade_republic_provider
      raise CredentialsError, "No Trade Republic provider configured for item #{trade_republic_item.id}"
    end

    portfolio = fetch_portfolio_with_refresh

    import_cash_account(portfolio[:cash])
    import_securities_account(portfolio[:securities])

    trade_republic_item.upsert_trade_republic_snapshot!(stats)
  rescue Provider::TradeRepublic::SessionExpiredError
    Rails.logger.warn "TradeRepublicItem::Importer - Session expired and could not be refreshed; clearing session"
    trade_republic_item.update!(status: :requires_update, session_token: nil, refresh_token: nil)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    # Fetch the portfolio, transparently refreshing the session once on expiry.
    def fetch_portfolio_with_refresh
      token = trade_republic_item.session_token
      raise CredentialsError, "No stored Trade Republic session" if token.blank?

      begin
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
        trade_republic_provider.fetch_portfolio(session_token: token)
      rescue Provider::TradeRepublic::SessionExpiredError
        refreshed = refresh_session!
        raise unless refreshed

        stats["session_refreshes"] = stats.fetch("session_refreshes", 0) + 1
        trade_republic_provider.fetch_portfolio(session_token: trade_republic_item.session_token)
      end
    end

    def refresh_session!
      refresh = trade_republic_item.refresh_token
      return false if refresh.blank?

      Rails.logger.info "TradeRepublicItem::Importer - Refreshing Trade Republic session"
      tokens = trade_republic_provider.refresh_session(refresh_token: refresh)

      trade_republic_item.update!(
        session_token: tokens[:session_token],
        refresh_token: tokens[:refresh_token].presence || refresh,
        expires_at: 2.hours.from_now,
        status: :good
      )
      true
    rescue Provider::TradeRepublic::SessionExpiredError
      false
    end

    def import_cash_account(cash)
      return if cash.blank?

      balance = cash[:balance].to_d
      tr_account = trade_republic_item.trade_republic_accounts.find_or_initialize_by(
        trade_republic_account_id: CASH_EXTERNAL_ID
      )
      tr_account.upsert_from_trade_republic!(
        name: I18n.t("trade_republic_items.account_names.cash", default: "Trade Republic Cash"),
        account_type: "depository",
        currency: cash[:currency] || "EUR",
        current_balance: balance,
        cash_balance: balance
      )

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end

    def import_securities_account(securities)
      return if securities.blank?

      positions = Array(securities[:positions])
      # Skip creating an empty securities account so users without a portfolio
      # only see their cash account.
      return if positions.empty? && securities[:value].to_d.zero?

      tr_account = trade_republic_item.trade_republic_accounts.find_or_initialize_by(
        trade_republic_account_id: SECURITIES_EXTERNAL_ID
      )
      tr_account.upsert_from_trade_republic!(
        name: I18n.t("trade_republic_items.account_names.securities", default: "Trade Republic Portfolio"),
        account_type: "investment",
        currency: securities[:currency] || "EUR",
        current_balance: securities[:value].to_d,
        cash_balance: 0
      )
      tr_account.upsert_holdings_snapshot!(positions)

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
      stats["holdings_found"] = stats.fetch("holdings_found", 0) + positions.size
    end
end
