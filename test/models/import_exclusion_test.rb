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
end
