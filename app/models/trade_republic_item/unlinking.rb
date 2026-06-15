# frozen_string_literal: true

module TradeRepublicItem::Unlinking
  # Encapsulates unlinking logic for a Trade Republic item.
  extend ActiveSupport::Concern

  # Idempotently remove all connections between this item and local accounts.
  # - Detaches any AccountProvider links for each TradeRepublicAccount
  # - Detaches Holdings that point at those AccountProvider links
  def unlink_all!(dry_run: false)
    results = []

    trade_republic_accounts.find_each do |provider_account|
      links = AccountProvider.where(provider_type: "TradeRepublicAccount", provider_id: provider_account.id).to_a
      link_ids = links.map(&:id)
      result = {
        provider_account_id: provider_account.id,
        name: provider_account.name,
        provider_link_ids: link_ids
      }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          if link_ids.any?
            Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil)
          end

          links.each(&:destroy!)
        end
      rescue StandardError => e
        Rails.logger.warn(
          "TradeRepublicItem Unlinker: failed to fully unlink provider account ##{provider_account.id} " \
          "(links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        result[:error] = e.message
      end
    end

    results
  end
end
