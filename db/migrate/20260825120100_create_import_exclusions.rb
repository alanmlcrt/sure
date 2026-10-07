# frozen_string_literal: true

class CreateImportExclusions < ActiveRecord::Migration[7.2]
  def change
    # Exact transaction names a family never wants imported (e.g. a recurring
    # card-settlement line like "RELEVE CARTE" that duplicates itemized
    # entries already imported elsewhere). Checked at row-generation time so
    # a re-import doesn't recreate transactions the user deleted on purpose.
    #
    # Fork-only. Originally versioned 20260825120000, which upstream later
    # reused for AddConsumedAmountToGoals; renumbered, and idempotent because
    # databases that ran the old version already have the table.
    create_table :import_exclusions, id: :uuid, if_not_exists: true do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false

      t.timestamps
    end

    add_index :import_exclusions, [ :family_id, :name ], unique: true, if_not_exists: true
  end
end
