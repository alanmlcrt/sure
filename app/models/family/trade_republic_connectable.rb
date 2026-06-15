module Family::TradeRepublicConnectable
  extend ActiveSupport::Concern

  included do
    has_many :trade_republic_items, dependent: :destroy
  end

  def can_connect_trade_republic?
    true
  end

  # Returns the single Trade Republic connection for this family, creating an
  # (unauthenticated) one if needed. Trade Republic only supports one logged-in
  # session per phone number, so we keep a single item per family.
  def trade_republic_item
    trade_republic_items.active.ordered.first ||
      trade_republic_items.create!(name: "Trade Republic Connection").tap(&:set_trade_republic_institution_defaults!)
  end

  def has_trade_republic_credentials?
    trade_republic_items.active.where.not(session_token: [ nil, "" ]).exists?
  end
end
