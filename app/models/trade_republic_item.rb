# frozen_string_literal: true

class TradeRepublicItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :session_token
    encrypts :refresh_token
    encrypts :pending_process_id
  end

  validates :name, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :trade_republic_accounts, dependent: :destroy

  scope :active, -> { where(scheduled_for_deletion: false) }
  # Only items with a stored session (or refresh) token can be auto-synced.
  scope :syncable, -> { active.where.not(session_token: [ nil, "" ]) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_trade_republic_data(sync: nil)
    provider = trade_republic_provider
    raise StandardError, "Trade Republic provider is not configured" unless provider

    TradeRepublicItem::Importer.new(self, trade_republic_provider: provider, sync: sync).import
  rescue StandardError => e
    Rails.logger.error "TradeRepublicItem #{id} - Failed to import: #{e.message}"
    raise
  end

  def process_accounts
    return [] if trade_republic_accounts.empty?

    results = []
    linked_trade_republic_accounts.includes(account_provider: :account).each do |tr_account|
      account = tr_account.current_account
      next unless account
      next if account.pending_deletion? || account.disabled?

      begin
        result = TradeRepublicAccount::Processor.new(tr_account).process
        results << { trade_republic_account_id: tr_account.id, success: true, result: result }
      rescue StandardError => e
        Rails.logger.error "TradeRepublicItem #{id} - Failed to process account #{tr_account.id}: #{e.message}"
        results << { trade_republic_account_id: tr_account.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    accounts.map do |account|
      next if account.pending_deletion? || account.disabled?

      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue StandardError => e
      Rails.logger.error "TradeRepublicItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
      { account_id: account.id, success: false, error: e.message }
    end.compact
  end

  def upsert_trade_republic_snapshot!(payload)
    update!(raw_payload: payload)
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def session_active?
    session_token.present? && (expires_at.nil? || expires_at.future?)
  end

  # Credentials are configured as soon as we hold a session token. The phone/PIN
  # are never stored; the session is established via the interactive 2FA flow.
  def credentials_configured?
    session_token.present?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("trade_republic_items.trade_republic_item.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("trade_republic_items.trade_republic_item.sync_status.all_synced", count: linked)
    else
      I18n.t("trade_republic_items.trade_republic_item.sync_status.partial_sync", linked_count: linked, unlinked_count: unlinked)
    end
  end

  def linked_accounts_count
    trade_republic_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    trade_republic_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    trade_republic_accounts.count
  end

  # Accounts linked via AccountProvider
  def linked_trade_republic_accounts
    trade_republic_accounts.joins(:account_provider)
  end

  def unlinked_trade_republic_accounts
    trade_republic_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  # All Sure accounts linked to this item
  def accounts
    trade_republic_accounts
      .includes(account_provider: :account)
      .filter_map(&:current_account)
      .uniq
  end

  def institution_display_name
    institution_name.presence || "Trade Republic"
  end

  def set_trade_republic_institution_defaults!
    update!(
      institution_name: "Trade Republic",
      institution_domain: "traderepublic.com",
      institution_url: "https://traderepublic.com",
      institution_color: "#000000"
    )
  end
end
