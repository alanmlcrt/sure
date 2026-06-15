# frozen_string_literal: true

class TradeRepublicAccount::Processor
  include TradeRepublicAccount::DataHelpers

  attr_reader :trade_republic_account

  def initialize(trade_republic_account)
    @trade_republic_account = trade_republic_account
  end

  def process
    account = trade_republic_account.current_account
    return unless account

    Rails.logger.info "TradeRepublicAccount::Processor - Processing account #{trade_republic_account.id} -> Sure account #{account.id}"

    update_account_balance(account)

    holdings_count = Array(trade_republic_account.raw_holdings_payload).size
    if holdings_count.positive?
      Rails.logger.info "TradeRepublicAccount::Processor - Processing #{holdings_count} holdings"
      TradeRepublicAccount::HoldingsProcessor.new(trade_republic_account).process
    end

    account.broadcast_sync_complete

    { holdings_processed: holdings_count.positive? }
  end

  private

    def update_account_balance(account)
      total_balance = trade_republic_account.current_balance || 0
      cash_balance = trade_republic_account.cash_balance || 0

      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: trade_republic_account.currency || account.currency
      )
      account.save!

      # Anchor valuation so reverse-sync / balance series stay correct.
      account.set_current_balance(total_balance)
    end
end
