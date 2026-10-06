# Imports transactions from a multi-sheet Excel (.xlsx) bank export in one go,
# whatever bank produced it. Each sheet is one account: on the selection step
# the user ticks the sheets to import, maps each to an app account, and checks
# the guessed table layout (title rows to skip, date/label/amount columns).
#
# Nothing is hardcoded per bank; the guesses are only defaults:
#   - title rows above the table are detected (see .guess_header_row)
#   - rows below the header that hold no value (sub-headers, notes) are dropped
#   - split debit/credit columns get a computed signed amount column
#   - the date column is the one holding dates, the label column the one with
#     the most text, the amount column the computed one or a keyword match
class XlsxImport < Import
  has_one_attached :xlsx_file, dependent: :purge_later

  SelectionError = Class.new(StandardError)

  MAX_XLSX_SIZE = 15.megabytes
  XLSX_EXTENSIONS = %w[.xlsx].freeze

  # ponytail: keyword match on the accent-stripped header, covering the usual
  # bank-export wordings in the app's supported locales (en fr de es it tr nb
  # ca ro ru pl pt nl hu vi uk zh); extend when an export isn't recognised (the
  # user can always pick the columns by hand).
  DEBIT_HEADER_RE = /\A(debit|debet|withdrawal|paid out|money out|outflow|soll\b|ausgang|cargo|addebit|dare\b|uscit|carrec|af\b|ut\b|obciaz|borc|terheles|ghi no|дебет|расход|списан|видат|支出|借方)/i
  CREDIT_HEADER_RE = /\A(credit|deposit|paid in|money in|inflow|haben\b|eingang|abono|accredit|avere\b|entrat|abonament|bij\b|inn\b|uznani|alacak|jovairas|ghi co|кредит|приход|зачислен|надходж|зарахув|收入|存入|贷方|貸方)/i
  AMOUNT_HEADER_RE = /\A(amount|montant|betrag|importe|importo|import\b|valor|bedrag|kwota|suma\b|tutar|osszeg|bel[oø]p|so tien|сумм|сума|金额|金額)/i
  NAME_HEADER_RE = /\A(libelle|description|descripcion|descricao|descrizione|descriere|beschreibung|beskrivelse|label|payee|merchant|details?|detalii|memo|narrative|text|tekst|concepto|concepte|verwendungszweck|beneficiaire|operation|omschrijving|causale|opis|ac[iı]klama|kozlemeny|leiras|noi dung|dien giai|описан|назначен|опис|призначен|摘要|交易描述|说明|說明|备注|備註)/i
  VALUE_DATE_HEADER_RE = /\A(valeur|value|valuta|wertstellung|fecha valor|date de valeur|data valuta|data waluty|data valor|дата валют|ngay hieu luc|起息)/i
  BALANCE_HEADER_RE = /\A(solde|balance|saldo|kontostand|running|sold\b|bakiye|egyenleg|остат|баланс|залиш|so du|余额|餘額|結餘)/i
  TEXT_DATE_RE = %r{\A\d{1,4}[./-]\d{1,2}[./-]\d{1,4}\z}

  # How many rows below a candidate header are inspected to confirm it.
  HEADER_LOOKAHEAD = 3

  # One sheet read as a table. +data+ rows are arrays of typed cells aligned
  # with +headers+; +columns+ holds the guessed { date:, name:, amount: } indexes.
  SheetTable = Struct.new(:name, :rows_to_skip, :headers, :data, :columns, keyword_init: true) do
    def importable?
      columns[:date].present? && columns[:amount].present?
    end

    # First rows as display strings, for the preview.
    def sample
      data.first(2).map do |row|
        headers.each_index.map { |i| row[i].is_a?(BigDecimal) ? row[i].to_s("F").delete_suffix(".0") : row[i].to_s }
      end
    end
  end

  class << self
    def create_from_upload!(family:, file:)
      import = create!(type: name, family: family, date_format: family.date_format)
      import.xlsx_file.attach(
        io: file.open,
        filename: file.original_filename,
        content_type: file.content_type
      )
      import
    end

    def valid_upload?(file)
      XLSX_EXTENSIONS.include?(File.extname(file.original_filename.to_s).downcase)
    end

    # 0-based index of the table's header row in +rows+ (arrays of typed cells),
    # i.e. the number of title rows to skip. The header is the first label row
    # (2+ text cells, no values) that is directly followed by data, i.e. mostly
    # rows holding at least a date and an amount. Falls back to 0.
    # ponytail: heuristic; a wrong guess is fixed by the user on the selection step.
    def guess_header_row(rows)
      rows.each_index.find do |index|
        next false unless label_row?(rows[index])

        # Lone cells (sub-headers like "Card XXXX 1234", notes) say nothing either way.
        body = rows.drop(index + 1).reject { |row| distinct_cells(row).size < 2 }.first(HEADER_LOOKAHEAD)
        # Another label row just below means this one is a title or summary
        # block above the real header (e.g. "Account | Owner").
        next false if body.empty? || body.any? { |row| label_row?(row) }

        # At least half look like transactions (a date and an amount); the rest
        # may be a totals footer.
        body.count { |row| row.count { |cell| value_cell?(cell) } >= 2 } * 2 >= body.size
      end || 0
    end

    def label_row?(row)
      labels = distinct_cells(row)
      labels.size >= 2 && labels.none? { |cell| value_cell?(cell) }
    end

    # Merged cells (titles, banners spanning the table) repeat one value in
    # every cell they cover, so they count once.
    def distinct_cells(row)
      row.reject(&:blank?).uniq
    end

    # A date or a number, typed or written as text ("15/03/2024", "-1 234,56 €",
    # "12.50 EUR").
    def value_cell?(cell)
      case cell
      when Date, Numeric then true
      else cell.to_s.gsub(/\p{Sc}|\p{Space}|\A[A-Z]{3}|[A-Z]{3}\z/, "").match?(/\A[-+]?\d[\d.,\/:'-]*\z/)
      end
    end
  end

  # --- Workbook -------------------------------------------------------------

  def workbook
    @workbook ||= Import::XlsxWorkbook.open(xlsx_file.download)
  end

  # rows_to_skip: { sheet_name => Integer } overrides for the guessed header.
  def sheet_tables(rows_to_skip: {})
    workbook.visible_sheets.filter_map { |sheet| sheet_table(sheet.name, rows_to_skip[sheet.name]) }
  end

  def sheet_table(sheet_name, rows_to_skip = nil)
    sheet = workbook.visible_sheets.find { |s| s.name == sheet_name && s.path }
    return nil unless sheet

    table = workbook.rows(sheet.name)
    return nil if table.empty?

    skip = rows_to_skip.present? ? rows_to_skip.to_i.clamp(0, table.size - 1) : self.class.guess_header_row(table)
    header = table[skip]
    data = table.drop(skip + 1).select { |row| row.any? { |cell| self.class.value_cell?(cell) } }
    header, data = add_amount_from_debit_credit(header, data)

    width = [ header.size, *data.map(&:size) ].max
    headers = Array.new(width) { |i| header[i].to_s.strip.presence || I18n.t("imports.xlsx.column", number: i + 1) }

    SheetTable.new(name: sheet.name, rows_to_skip: skip, headers: headers, data: data, columns: guess_columns(headers, data))
  end

  # --- Selection step -------------------------------------------------------

  # selections: array of { "sheet_name", "selected", "account_id" ("new" or an
  # id), "account_name", "rows_to_skip", "date_col", "name_col", "amount_col" }.
  def apply_sheet_selections!(selections)
    chosen = Array(selections).select { |s| ActiveModel::Type::Boolean.new.cast(s["selected"]) }

    transaction do
      new_rows = chosen.flat_map do |selection|
        table = sheet_table(selection["sheet_name"].to_s, selection["rows_to_skip"])
        raise SelectionError, I18n.t("imports.xlsx.unknown_sheet", sheet: selection["sheet_name"]) unless table

        columns = %w[date name amount].to_h { |key| [ key.to_sym, selection["#{key}_col"].presence&.to_i ] }
        raise SelectionError, I18n.t("imports.xlsx.missing_columns", sheet: table.name) unless columns[:date] && columns[:amount]

        account = resolve_account(selection, table)
        table.data.filter_map { |row| row_attributes(row, columns, account) }
      end

      rows.destroy_all
      new_rows.reject! { |row| excluded_row_name?(row[:name]) }
      new_rows.each_with_index { |row, index| row[:source_row_number] = index + 1 }
      Import::Row.insert_all!(new_rows) if new_rows.any?
      # destroy_all loaded the (now empty) rows association and insert_all!
      # bypasses it, leaving a stale cache. Reset so import! re-queries.
      rows.reset
      update_column(:rows_count, rows.count)
    end
  end

  # --- Publish --------------------------------------------------------------

  def import!
    transaction do
      accounts_by_id = family.accounts.where(id: rows.distinct.pluck(:account)).index_by(&:id)

      new_transactions = []
      updated_entries = []
      claimed_entry_ids = Set.new

      rows.each do |row|
        mapped_account = accounts_by_id[row.account]
        next if mapped_account.nil? # account removed mid-import; skip defensively

        adapter = Account::ProviderImportAdapter.new(mapped_account)
        duplicate_entry = adapter.find_duplicate_transaction(
          date: row.date_iso,
          amount: row.signed_amount,
          currency: row.currency,
          name: row.name,
          exclude_entry_ids: claimed_entry_ids
        )

        if duplicate_entry
          duplicate_entry.import = self
          duplicate_entry.import_locked = true
          updated_entries << duplicate_entry
          claimed_entry_ids.add(duplicate_entry.id)
        else
          new_transactions << Transaction.new(
            entry: Entry.new(
              account: mapped_account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: row.currency,
              import: self,
              import_locked: true
            )
          )
        end
      end

      updated_entries.each(&:save!)
      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  # --- Import flow hooks ----------------------------------------------------

  def requires_csv_workflow?
    false
  end

  def uploaded?
    xlsx_file.attached?
  end

  def configured?
    uploaded? && rows_count > 0
  end

  def cleaned?
    configured? && rows.all?(&:valid?)
  end

  def publishable?
    cleaned? && mappings.all?(&:valid?)
  end

  def cleaned_from_validation_stats?(invalid_rows_count:)
    configured? && invalid_rows_count.zero?
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    cleaned_from_validation_stats?(invalid_rows_count: invalid_rows_count) && mappings.all?(&:valid?)
  end

  def column_keys
    %i[date name amount currency]
  end

  def required_column_keys
    %i[date amount]
  end

  def mapping_steps
    [] # accounts are mapped on the sheet-selection step, not via Import::Mapping
  end

  def dry_run
    { transactions: rows_count }
  end

  private
    def resolve_account(selection, table)
      account_id = selection["account_id"].to_s
      return family.accounts.find(account_id) if account_id.present? && account_id != "new"

      name = selection["account_name"].presence || table.name
      # Re-applying the selection reuses the account this import already created.
      accounts.find_by(name: name) || family.accounts.create!(
        name: name,
        balance: 0,
        currency: family.currency,
        import: self,
        accountable: Depository.new
      )
    end

    # nil for rows that aren't transactions: no date (totals, notes) or a zero
    # amount (informational lines such as rate changes).
    def row_attributes(row, columns, account)
      date = row[columns[:date]]
      amount = row[columns[:amount]]
      return nil unless date_cell?(date)
      return nil if amount.is_a?(Numeric) && amount.zero?

      {
        import_id: id,
        account: account.id, # resolved at import! time
        date: date.is_a?(Date) ? date.strftime(date_format) : date.to_s.strip,
        name: (columns[:name] && row[columns[:name]]).to_s.strip.presence || default_row_name,
        amount: amount.is_a?(Numeric) ? amount.to_d.to_s("F") : sanitize_number(amount),
        currency: account.currency.presence || family.currency
      }
    end

    def date_cell?(cell)
      cell.is_a?(Date) || cell.to_s.strip.match?(TEXT_DATE_RE)
    end

    def guess_columns(headers, data)
      # Prefer the operation date over a value date when both are present.
      value_dates = header_indexes(headers, VALUE_DATE_HEADER_RE)
      date = best_column(data, except: value_dates) { |cell| date_cell?(cell) ? 1 : 0 } ||
        best_column(data) { |cell| date_cell?(cell) ? 1 : 0 }
      amount = headers.index(computed_amount_header) ||
        headers.index { |header| plain_text(header).match?(AMOUNT_HEADER_RE) } ||
        only_numeric_column(data, except: [ date, *header_indexes(headers, BALANCE_HEADER_RE) ])
      name = headers.index { |header| plain_text(header).match?(NAME_HEADER_RE) } ||
        best_column(data, except: [ date, amount ]) do |cell|
          cell.is_a?(String) && !self.class.value_cell?(cell) ? cell.length : 0
        end

      { date: date, name: name, amount: amount }
    end

    def header_indexes(headers, pattern)
      headers.each_index.select { |i| plain_text(headers[i]).match?(pattern) }
    end

    # The amount column when the header is unknown, but only if it is the sole
    # numeric column; with a balance column too, the user picks.
    def only_numeric_column(data, except: [])
      sample = data.first(50)
      width = sample.map(&:size).max.to_i
      numeric = (0...width).reject { |i| except.include?(i) }.select do |i|
        sample.count { |row| !date_cell?(row[i]) && self.class.value_cell?(row[i]) } * 2 >= sample.size
      end
      numeric.one? ? numeric.first : nil
    end

    # Index of the column with the highest score over the first rows.
    def best_column(data, except: [])
      scores = Hash.new(0)
      data.first(50).each do |row|
        row.each_with_index { |cell, index| scores[index] += yield(cell) unless except.include?(index) }
      end
      best = scores.max_by(&:last)
      best && best.last.positive? ? best.first : nil
    end

    # Appends a signed "credit - debit" column when amounts are split in two.
    def add_amount_from_debit_credit(header, data)
      labels = header.map { |cell| plain_text(cell) }
      debit_col = labels.index { |label| label.match?(DEBIT_HEADER_RE) }
      credit_col = labels.index { |label| label.match?(CREDIT_HEADER_RE) }
      return [ header, data ] unless debit_col && credit_col

      width = [ header.size, *data.map(&:size) ].max
      pad = ->(row) { row + Array.new(width - row.size) }
      [
        pad.(header) + [ computed_amount_header ],
        data.map { |row| pad.(row) + [ signed_amount(row[credit_col], row[debit_col]) ] }
      ]
    end

    # ponytail: numeric cells only; debit/credit stored as text leave the
    # computed cell blank and the user picks another amount column.
    def signed_amount(credit, debit)
      return nil unless credit.is_a?(Numeric) || debit.is_a?(Numeric)

      (credit.is_a?(Numeric) ? credit.abs : 0) - (debit.is_a?(Numeric) ? debit.abs : 0)
    end

    def computed_amount_header
      I18n.t("imports.xlsx.computed_amount_header")
    end

    def plain_text(cell)
      cell.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").strip
    end
end
