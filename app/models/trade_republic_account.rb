# frozen_string_literal: true

class TradeRepublicAccount < ApplicationRecord
  include TradeRepublicAccount::DataHelpers

  belongs_to :trade_republic_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :trade_republic_account_id,
            uniqueness: { scope: :trade_republic_item_id, allow_nil: true }

  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  def current_account
    account
  end

  # Idempotently create or update the AccountProvider link.
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    reload_account_provider
    account_provider
  end

  def upsert_from_trade_republic!(name:, account_type:, currency:, current_balance: nil, cash_balance: nil)
    attrs = {
      name: name,
      account_type: account_type,
      currency: currency || "EUR",
      provider: "Trade Republic"
    }
    attrs[:current_balance] = current_balance.to_d unless current_balance.nil?
    attrs[:cash_balance] = cash_balance.to_d unless cash_balance.nil?

    update!(attrs)
  end

  def upsert_holdings_snapshot!(holdings_data)
    update!(
      raw_holdings_payload: holdings_data || [],
      last_holdings_sync: Time.current
    )
  end

  # Maps the Trade Republic account_type to a Sure accountable class name.
  def inferred_accountable_type
    case account_type
    when "investment" then "Investment"
    else "Depository"
    end
  end
end
