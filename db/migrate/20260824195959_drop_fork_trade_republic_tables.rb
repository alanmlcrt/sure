# Fork-only. This fork shipped its own Trade Republic integration
# (migration 20260615120000) before upstream added theirs. Both use the same
# table names with different columns, so upstream's
# CreateTradeRepublicItemsAndAccounts (20260824200000) would fail on databases
# that ran the fork's version. Drop the old tables first; the Sure accounts they
# were linked to are kept and become manual until Trade Republic is reconnected.
class DropForkTradeRepublicTables < ActiveRecord::Migration[7.2]
  def up
    # ponytail: fresh databases never had the fork's tables, nothing to do there
    return unless table_exists?(:trade_republic_items)

    execute <<~SQL
      UPDATE holdings SET account_provider_id = NULL
      WHERE account_provider_id IN (SELECT id FROM account_providers WHERE provider_type = 'TradeRepublicAccount')
    SQL
    execute "DELETE FROM account_providers WHERE provider_type = 'TradeRepublicAccount'"
    execute "DELETE FROM syncs WHERE syncable_type = 'TradeRepublicItem'"

    drop_table :trade_republic_accounts, if_exists: true
    drop_table :trade_republic_items
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
