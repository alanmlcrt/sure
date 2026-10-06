class Import::SheetSelectionsController < ApplicationController
  layout "imports"

  before_action :set_import
  before_action :ensure_xlsx_import

  # Also serves the "Refresh" button (a GET of the same form) so edited
  # rows-to-skip values re-read the tables without saving anything.
  def show
    redirect_to new_import_path, alert: t(".finalize_upload") and return unless @import.uploaded?

    @import.assign_attributes(format_params) # keep the formats picked before a refresh
    @selections = sheet_selection_params.index_by { |s| s["table_key"] }
    @tables = @import.sheet_tables(rows_to_skip: @selections.transform_values { |s| s["rows_to_skip"] })
    @accounts = accessible_accounts.visible.alphabetically
  rescue Import::XlsxWorkbook::Error => e
    redirect_to new_import_path, alert: t(".invalid_file", message: e.message)
  end

  def update
    @import.update!(format_params)
    @import.apply_sheet_selections!(sheet_selection_params)

    if @import.rows_count.zero?
      redirect_to import_sheet_selection_path(@import), alert: t(".no_sheets_selected")
    else
      redirect_to import_clean_path(@import), notice: t(".sheets_imported")
    end
  rescue XlsxImport::SelectionError, ActiveRecord::RecordInvalid => e
    redirect_to import_sheet_selection_path(@import), alert: e.message
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def ensure_xlsx_import
      redirect_to import_path(@import) unless @import.is_a?(XlsxImport)
    end

    def format_params
      params.fetch(:import, {}).permit(:date_format, :number_format, :signage_convention)
    end

    # params[:import][:sheets] is a hash keyed by index, one entry per sheet.
    def sheet_selection_params
      sheets = params.dig(:import, :sheets) || {}
      sheets.values.map do |sheet|
        sheet.permit(:table_key, :sheet_name, :selected, :account_id, :account_name, :rows_to_skip, :date_col, :name_col, :amount_col, :sign_col).to_h
      end
    end
end
