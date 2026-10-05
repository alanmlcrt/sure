require "test_helper"

class Import::SheetSelectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = @user.family.imports.create!(type: "XlsxImport", date_format: "%Y-%m-%d")
    @import.xlsx_file.attach(
      io: file_fixture("imports/bank_formats.xlsx").open,
      filename: "bank_formats.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end

  test "show lists the sheets with their guessed layout" do
    get import_sheet_selection_url(@import)

    assert_response :success
    assert_select "input[name='import[sheets][1][rows_to_skip]'][value='4']" # "titles" sheet
  end

  test "update imports the selected sheets" do
    put import_sheet_selection_url(@import), params: {
      import: {
        date_format: "%Y-%m-%d",
        number_format: "1,234.56",
        signage_convention: "inflows_positive",
        sheets: {
          "0" => { sheet_name: "a1_simple", selected: "1", account_id: accounts(:depository).id, rows_to_skip: "0", date_col: "0", name_col: "1", amount_col: "2" },
          "1" => { sheet_name: "titles", selected: "0" }
        }
      }
    }

    assert_redirected_to import_clean_url(@import)
    assert_equal 3, @import.reload.rows_count
  end
end
