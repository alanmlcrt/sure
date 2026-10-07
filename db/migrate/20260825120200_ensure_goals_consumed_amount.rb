# Fork-only. Databases that ran the fork's CreateImportExclusions under
# version 20260825120000 have that version recorded, so upstream's
# AddConsumedAmountToGoals (same version) is skipped there. Apply it if missing.
class EnsureGoalsConsumedAmount < ActiveRecord::Migration[7.2]
  def up
    return if column_exists?(:goals, :consumed_amount)

    add_column :goals, :consumed_amount, :decimal, precision: 19, scale: 4, null: false, default: 0
    add_check_constraint :goals, "consumed_amount >= 0", name: "chk_goals_consumed_amount_non_negative"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
