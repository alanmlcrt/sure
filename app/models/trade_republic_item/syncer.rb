# frozen_string_literal: true

class TradeRepublicItem::Syncer
  include SyncStats::Collector

  attr_reader :trade_republic_item

  def initialize(trade_republic_item)
    @trade_republic_item = trade_republic_item
  end

  def perform_sync(sync)
    Rails.logger.info "TradeRepublicItem::Syncer - Starting sync for item #{trade_republic_item.id}"

    # Phase 1: Import data from the Trade Republic sidecar (cash + portfolio)
    sync.update!(status_text: I18n.t("trade_republic_items.sync.status.importing")) if sync.respond_to?(:status_text)
    trade_republic_item.import_latest_trade_republic_data(sync: sync)

    # Phase 2: Flag accounts that still need to be linked to a Sure account
    finalize_setup_counts(sync)

    # Phase 3: Process data for linked accounts (balances + holdings)
    linked = trade_republic_item.linked_trade_republic_accounts.includes(account_provider: :account)
    if linked.any?
      sync.update!(status_text: I18n.t("trade_republic_items.sync.status.processing")) if sync.respond_to?(:status_text)
      trade_republic_item.process_accounts

      sync.update!(status_text: I18n.t("trade_republic_items.sync.status.calculating")) if sync.respond_to?(:status_text)
      trade_republic_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked.filter_map { |pa| pa.current_account&.id }
      collect_trades_stats(sync, account_ids: account_ids, source: "trade_republic")
      collect_holdings_stats(sync, holdings_count: count_holdings, label: "processed")
    end

    collect_health_stats(sync, errors: nil)
  rescue Provider::TradeRepublic::SessionExpiredError => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
  end

  private

    def count_holdings
      trade_republic_item.linked_trade_republic_accounts.sum { |pa| Array(pa.raw_holdings_payload).size }
    end

    def finalize_setup_counts(sync)
      unlinked_count = trade_republic_item.unlinked_accounts_count

      if unlinked_count > 0
        trade_republic_item.update!(pending_account_setup: true)
        sync.update!(status_text: I18n.t("trade_republic_items.sync.status.needs_setup", count: unlinked_count)) if sync.respond_to?(:status_text)
      else
        trade_republic_item.update!(pending_account_setup: false)
      end

      collect_setup_stats(sync, provider_accounts: trade_republic_item.trade_republic_accounts)
    end
end
