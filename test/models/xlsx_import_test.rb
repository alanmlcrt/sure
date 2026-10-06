require "test_helper"

class XlsxImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FIXTURE = "test/fixtures/files/imports/sample_bank_export.xlsx".freeze
  CPT_SHEET = "Cpt 02619 00099999901".freeze
  CB_SHEET = "CB 02619 00099999901 # 052026".freeze

  setup do
    @family = families(:dylan_family)
    @import = XlsxImport.create!(family: @family, date_format: "%Y-%m-%d")
    @import.xlsx_file.attach(
      io: File.open(Rails.root.join(FIXTURE)),
      filename: "sample_bank_export.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end

  test "reads every visible sheet, skipping title rows and guessing columns" do
    tables = @import.sheet_tables.index_by(&:name)
    assert_equal [ "Vos comptes", CPT_SHEET, CB_SHEET ], tables.keys

    cpt = tables[CPT_SHEET]
    assert_equal 4, cpt.rows_to_skip
    assert_equal "Amount (credit - debit)", cpt.headers.last
    assert_equal({ date: 0, name: 2, amount: 7 }, cpt.columns)
    assert cpt.importable?

    cb = tables[CB_SHEET]
    assert_equal({ date: 0, name: 1, amount: 2 }, cb.columns)
    assert_equal 3, cb.data.size # the "Carte Mastercard" sub-header line is dropped

    assert_not tables["Vos comptes"].importable? # summary sheet has no dates
  end

  test "imports several sheets into their accounts in one go" do
    existing = accounts(:depository)
    cpt, cb = @import.sheet_tables.index_by(&:name).values_at(CPT_SHEET, CB_SHEET)

    assert_difference -> { @family.accounts.count }, 1 do
      @import.apply_sheet_selections!([
        selection(cpt, "account_id" => "new", "account_name" => "Checking FR"),
        selection(cb, "account_id" => existing.id),
        { "sheet_name" => "Vos comptes", "selected" => "0" }
      ])
    end

    checking = @family.accounts.find_by!(name: "Checking FR")
    assert_equal 5, @import.rows_count # the zero-amount cpt line is skipped
    assert_equal 2, @import.rows.where(account: checking.id).count
    assert_equal 3, @import.rows.where(account: existing.id).count

    assert_difference -> { Entry.count }, 5 do
      @import.publish
    end
    assert @import.complete?
    assert_equal [ -12.34, 45.67 ], checking.entries.order(:date).pluck(:amount).map(&:to_f)
  end

  test "re-applying the selection reuses the account it created" do
    cpt = @import.sheet_tables.find { |t| t.name == CPT_SHEET }
    @import.apply_sheet_selections!([ selection(cpt, "account_id" => "new", "account_name" => "Checking FR") ])

    assert_no_difference -> { @family.accounts.count } do
      @import.apply_sheet_selections!([ selection(cpt, "account_id" => "new", "account_name" => "Checking FR") ])
    end
  end

  test "requires a date and an amount column" do
    cpt = @import.sheet_tables.find { |t| t.name == CPT_SHEET }

    assert_raises(XlsxImport::SelectionError) do
      @import.apply_sheet_selections!([ selection(cpt, "account_id" => "new", "amount_col" => "") ])
    end
  end

  # One sheet per bank-export layout, see generate_formats.py.
  # sheet => [rows to skip, date header, label header, amount header, first imported row]
  FORMATS = {
    "a1_simple" => [ 0, "Date", "Description", "Amount", [ "2024-03-01", "Coffee shop", "-3.5" ] ],
    "titles" => [ 4, "Date opération", "Libellé", "Montant", [ "2024-03-01", "PRLV EDF", "-80.12" ] ],
    "offset" => [ 5, "Date", "Payee", "Amount", [ "2024-04-01", "Bakery", "-4.1" ] ],
    "text_values" => [ 2, "Date", "Libellé", "Montant", [ "15/03/2024", "CARTE MONOPRIX", "-1234.56" ] ],
    "paid_in_out" => [ 3, "Date", "Description", "Amount (credit - debit)", [ "2024-05-01", "COUNCIL TAX", "-120.0" ] ],
    "key_values" => [ 4, "Booking date", "Text", "Amount", [ "2024-06-01", "Rent", "-900.0" ] ],
    "german" => [ 2, "Buchungstag", "Verwendungszweck", "Amount (credit - debit)", [ "2024-07-01", "Miete Juli", "-750.0" ] ],
    "totals_footer" => [ 0, "Date", "Label", "Amount", [ "2024-08-01", "Shop", "-10.0" ] ],
    "amount_first" => [ 0, "Date", "Payee", "Amount", [ "2024-09-01", "Streaming", "-15.99" ] ],
    "datetime" => [ 0, "Transaction date", "Merchant", "Amount", [ "2024-10-01", "Taxi", "-18.4" ] ],
    "two_line_header" => [ 1, "Date", "Libellé", "Amount (credit - debit)", [ "2024-11-01", "LOYER", "-700.0" ] ],
    "summary_block" => [ 3, "Date", "Libellé", "Montant", [ "2024-12-01", "ACHAT", "-20.0" ] ],
    "spanish" => [ 1, "Fecha", "Concepto", "Importe", [ "2024-01-10", "Supermercado", "-35.1" ] ],
    "unknown_amount_header" => [ 0, "Jour", "Opération", "Somme", [ "2024-02-01", "Boulangerie", "-2.3" ] ],
    "merged_banners" => [ 4, "Date", "Libellé", "Montant", [ "2026-08-18", "OPENAI CHATGPT", "-23.0" ] ],
    "polish" => [ 2, "Data operacji", "Opis", "Amount (credit - debit)", [ "2024-03-04", "Biedronka", "-45.2" ] ],
    "russian" => [ 1, "Дата", "Описание", "Сумма", [ "2024-04-01", "Пятёрочка", "-1250.5" ] ],
    "turkish" => [ 2, "İşlem tarihi", "Açıklama", "Tutar", [ "2024-05-02", "Market alışverişi", "-320.75" ] ],
    "chinese" => [ 1, "交易日期", "摘要", "Amount (credit - debit)", [ "2024-06-01", "超市购物", "-88.5" ] ]
  }.freeze

  test "finds the table and its columns in many bank layouts" do
    @import.xlsx_file.attach(
      io: File.open(Rails.root.join("test/fixtures/files/imports/bank_formats.xlsx")),
      filename: "bank_formats.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
    @import.number_format = "1 234,56" # for the text_values sheet
    tables = @import.sheet_tables.index_by(&:name)
    account = OpenStruct.new(id: "account", currency: "EUR")

    FORMATS.each do |sheet, (skip, date, name, amount, first_row)|
      table = tables.fetch(sheet)
      assert_equal skip, table.rows_to_skip, "#{sheet}: rows to skip"
      assert_equal [ date, name, amount ], table.columns.values_at(:date, :name, :amount).map { |i| i && table.headers[i] }, "#{sheet}: columns"

      imported = table.data.filter_map { |row| @import.send(:row_attributes, row, table.columns, account) }
      assert_equal first_row, imported.first.values_at(:date, :name, :amount), "#{sheet}: first row"
      assert_not imported.any? { |row| row[:date] == "Total" }, "#{sheet}: footer rows are skipped"
    end

    assert_not tables.fetch("notes_only").importable?
  end

  test "every supported locale translates the Excel import" do
    expected = locale_keys("en")

    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      assert_equal expected, locale_keys(locale), "config/locales/views/xlsx_imports/#{locale}.yml"
    end
  end

  test "guess_header_row finds the header after title rows in a text-only sheet" do
    rows = [
      [ "Bank statement" ],
      [ "Account", "FR76 3000 4000" ], # label row directly above the real header
      [],
      [ "Date", "Description", "Amount" ],
      [ "15/03/2024", "Coffee", "-3,50 €" ],
      [ "16/03/2024", "Salary", "2 000,00" ]
    ]

    assert_equal 3, XlsxImport.guess_header_row(rows)
  end

  test "guess_header_row defaults to the first row" do
    assert_equal 0, XlsxImport.guess_header_row([ [ "Date", "Amount" ], [ Date.new(2024, 1, 1), BigDecimal("1") ] ])
    assert_equal 0, XlsxImport.guess_header_row([ [ "just a note" ] ])
  end

  private
    # Leaf keys of a locale file, plural forms collapsed (their categories
    # differ per language).
    def locale_keys(locale)
      tree = YAML.load_file(Rails.root.join("config/locales/views/xlsx_imports/#{locale}.yml")).fetch(locale)
      flatten = ->(node, path) { node.is_a?(Hash) && !node.key?("other") ? node.flat_map { |k, v| flatten.(v, "#{path}.#{k}") } : [ path ] }
      flatten.(tree, "").sort
    end

    def selection(table, overrides = {})
      {
        "sheet_name" => table.name,
        "selected" => "1",
        "rows_to_skip" => table.rows_to_skip.to_s,
        "date_col" => table.columns[:date].to_s,
        "name_col" => table.columns[:name].to_s,
        "amount_col" => table.columns[:amount].to_s
      }.merge(overrides)
    end
end
