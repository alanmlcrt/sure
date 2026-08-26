require "test_helper"

class ImportExclusionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "name is unique per family, case-insensitively" do
    @family.import_exclusions.create!(name: "RELEVE CARTE")
    duplicate = @family.import_exclusions.new(name: "releve carte")

    assert_not duplicate.valid?
  end

  test "strips whitespace from name" do
    exclusion = @family.import_exclusions.create!(name: "  RELEVE CARTE  ")

    assert_equal "RELEVE CARTE", exclusion.name
  end

  test "delete_matching_transactions! destroys only entries with an exact, case-insensitive name match" do
    account = accounts(:depository)
    matching = account.entries.create!(name: "RELEVE CARTE", date: Date.current, amount: 10, currency: "USD", entryable: Transaction.new)
    other_case = account.entries.create!(name: "releve carte", date: Date.current, amount: 10, currency: "USD", entryable: Transaction.new)
    unrelated = account.entries.create!(name: "Groceries", date: Date.current, amount: 10, currency: "USD", entryable: Transaction.new)

    exclusion = @family.import_exclusions.create!(name: "RELEVE CARTE")

    assert_equal 2, exclusion.delete_matching_transactions!
    assert_not Entry.exists?(matching.id)
    assert_not Entry.exists?(other_case.id)
    assert Entry.exists?(unrelated.id)
  end
end
