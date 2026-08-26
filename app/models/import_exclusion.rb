# An exact transaction name a family never wants (re-)imported, e.g. a
# recurring card-settlement line whose detail is already imported elsewhere.
# Checked at row-generation time (Import#generate_rows_from_csv,
# XlsxImport#generate_rows_from_sheets) so re-importing the same file doesn't
# recreate a transaction the user deleted on purpose.
class ImportExclusion < ApplicationRecord
  belongs_to :family

  normalizes :name, with: ->(value) { value.to_s.strip }

  validates :name, presence: true, uniqueness: { scope: :family_id, case_sensitive: false }

  # Deletes existing transactions whose entry name exactly matches this
  # exclusion (case-insensitive) -- for callers offering to apply a newly
  # created exclusion retroactively, since the row-generation filter only
  # protects future imports. Returns the number of entries destroyed.
  def delete_matching_transactions!
    entries = matching_entries.to_a
    entries.each do |entry|
      entry.destroy!
      entry.sync_account_later
    end
    entries.size
  end

  private
    def matching_entries
      family.entries.where(entryable_type: "Transaction").where("LOWER(name) = ?", name.downcase)
    end
end
