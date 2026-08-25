# frozen_string_literal: true

class CreateImportExclusions < ActiveRecord::Migration[7.2]
  def change
    # Exact transaction names a family never wants imported (e.g. a recurring
    # card-settlement line like "RELEVE CARTE" that duplicates itemized
    # entries already imported elsewhere). Checked at row-generation time so
    # a re-import doesn't recreate transactions the user deleted on purpose.
    create_table :import_exclusions, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false

      t.timestamps
    end

    add_index :import_exclusions, [ :family_id, :name ], unique: true
  end
end
