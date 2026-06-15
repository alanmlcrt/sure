# frozen_string_literal: true

class TradeRepublicItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_trade_republic_item, only: [ :destroy, :sync, :setup_accounts, :complete_account_setup ]

  # Step 1 of login: send phone + PIN to Trade Republic, which dispatches a 2FA
  # code. We store the returned processId on the (single) family item so the
  # next request can complete the login. Credentials are never persisted.
  def initiate_auth
    item = Current.family.trade_republic_item

    begin
      process_id = item.trade_republic_provider.initiate_auth(
        phone_number: auth_params[:phone_number],
        pin: auth_params[:pin]
      )
      item.update!(
        phone_number: auth_params[:phone_number],
        pending_process_id: process_id,
        status: :good
      )

      render_panel(awaiting_tan: true)
    rescue Provider::TradeRepublic::Error => e
      render_panel(error_message: e.message, status: :unprocessable_entity)
    end
  end

  # Step 2 of login: exchange the 2FA code for session + refresh tokens, store
  # them, and kick off a background sync.
  def complete_auth
    item = Current.family.trade_republic_item

    if item.pending_process_id.blank?
      return render_panel(error_message: t(".no_pending_login"), status: :unprocessable_entity)
    end

    begin
      tokens = item.trade_republic_provider.complete_auth(
        process_id: item.pending_process_id,
        tan: auth_params[:tan]
      )
      item.update!(
        session_token: tokens[:session_token],
        refresh_token: tokens[:refresh_token],
        expires_at: 2.hours.from_now,
        pending_process_id: nil,
        status: :good
      )
      item.sync_later unless item.syncing?

      render_panel(notice: t(".success"))
    rescue Provider::TradeRepublic::Error => e
      render_panel(error_message: e.message, awaiting_tan: true, status: :unprocessable_entity)
    end
  end

  def sync
    @trade_republic_item.sync_later unless @trade_republic_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to settings_providers_path, notice: t(".success") }
      format.json { head :ok }
    end
  end

  def setup_accounts
    @unlinked_accounts = @trade_republic_item.unlinked_trade_republic_accounts.order(:name)
  end

  def complete_account_setup
    account_ids = Array(params[:account_ids]).reject(&:blank?)

    if account_ids.empty?
      redirect_to setup_accounts_trade_republic_item_path(@trade_republic_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    account_ids.each do |tr_account_id|
      tr_account = @trade_republic_item.trade_republic_accounts.find_by(id: tr_account_id)
      next unless tr_account
      next if tr_account.account_provider.present?

      ActiveRecord::Base.transaction do
        account = create_account_from_trade_republic(tr_account)
        tr_account.ensure_account_provider!(account)
      end

      created_count += 1
    rescue => e
      Rails.logger.error "TradeRepublicItemsController#complete_account_setup - Error linking #{tr_account_id}: #{e.message}"
      skipped_count += 1
    end

    if created_count.positive?
      @trade_republic_item.sync_later unless @trade_republic_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count.positive?
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_trade_republic_item_path(@trade_republic_item), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  def destroy
    @trade_republic_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  private

    def set_trade_republic_item
      @trade_republic_item = Current.family.trade_republic_items.find(params[:id])
    end

    def auth_params
      params.require(:trade_republic).permit(:phone_number, :pin, :tan)
    end

    def create_account_from_trade_republic(tr_account)
      accountable_class = tr_account.inferred_accountable_type.constantize

      account = Current.family.accounts.create!(
        name: tr_account.name,
        balance: tr_account.current_balance || 0,
        currency: tr_account.currency || "EUR",
        accountable: accountable_class.new
      )

      account.auto_share_with_family! if Current.family.share_all_by_default?
      account
    end

    # Renders the settings provider panel as a turbo-stream replacement so the
    # interactive login can advance steps without a full page reload.
    def render_panel(awaiting_tan: false, notice: nil, error_message: nil, status: :ok)
      @trade_republic_items = Current.family.trade_republic_items.ordered
      flash.now[:notice] = notice if notice.present?

      streams = [
        turbo_stream.replace(
          "trade_republic-providers-panel",
          partial: "settings/providers/trade_republic_panel",
          locals: {
            trade_republic_items: @trade_republic_items,
            awaiting_tan: awaiting_tan,
            error_message: error_message
          }
        )
      ]
      streams.concat(flash_notification_stream_items) if notice.present?

      render turbo_stream: streams, status: status
    end
end
