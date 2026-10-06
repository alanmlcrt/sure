require "test_helper"

class Import::SheetSelectionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

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

  test "show renders in every supported locale" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get import_sheet_selection_url(@import, locale: locale)

      assert_response :success, locale
      assert_select "h1", I18n.t("import.sheet_selections.show.title", locale: locale)
    end
  end

  test "imports an uploaded workbook end to end" do
    post imports_url, params: { import: { type: "XlsxImport", import_file: fixture_file_upload("imports/bank_formats.xlsx") } }
    import = @user.family.imports.where(type: "XlsxImport").order(:created_at).last
    assert_redirected_to import_sheet_selection_url(import)

    get import_sheet_selection_url(import)
    assert_response :success

    # The second of two accounts stacked in one sheet.
    table = import.sheet_tables.find { |t| t.key == "stacked_tables|1" }
    put import_sheet_selection_url(import), params: {
      import: {
        date_format: "%Y-%m-%d",
        number_format: "1,234.56",
        signage_convention: "inflows_positive",
        sheets: {
          "0" => {
            table_key: table.key, sheet_name: table.name, selected: "1", account_id: "new", account_name: "Livret A",
            rows_to_skip: table.rows_to_skip, date_col: table.columns[:date], name_col: table.columns[:name], amount_col: table.columns[:amount]
          }
        }
      }
    }
    assert_redirected_to import_clean_url(import)

    get import_clean_url(import)
    assert_response :success

    perform_enqueued_jobs { post publish_import_url(import) }

    assert import.reload.complete?, import.error
    account = @user.family.accounts.find_by!(name: "Livret A")
    assert_equal [ [ Date.new(2024, 2, 1), "Intérêts", -12.5 ], [ Date.new(2024, 3, 1), "Versement", -100.0 ] ],
                 account.entries.order(:date).map { |e| [ e.date, e.name, e.amount.to_f ] }
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
