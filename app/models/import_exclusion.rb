# An exact transaction name a family never wants (re-)imported, e.g. a
# recurring card-settlement line whose detail is already imported elsewhere.
# Checked at row-generation time (Import#generate_rows_from_csv,
# XlsxImport#generate_rows_from_sheets) so re-importing the same file doesn't
# recreate a transaction the user deleted on purpose.
class ImportExclusion < ApplicationRecord
  belongs_to :family

  normalizes :name, with: ->(value) { value.to_s.strip }

  validates :name, presence: true, uniqueness: { scope: :family_id, case_sensitive: false }
end
