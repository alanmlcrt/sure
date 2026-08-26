class ImportExclusionsController < ApplicationController
  def create
    @import_exclusion = Current.family.import_exclusions.new(import_exclusion_params)

    if @import_exclusion.save
      if apply_retroactively?
        deleted_count = @import_exclusion.delete_matching_transactions!
        notice = deleted_count.positive? ? t(".created_with_deletions", count: deleted_count) : t(".created")
      else
        notice = t(".created")
      end

      redirect_to imports_path, notice: notice
    else
      redirect_to imports_path, alert: @import_exclusion.errors.full_messages.to_sentence
    end
  end

  def destroy
    Current.family.import_exclusions.find(params[:id]).destroy!
    redirect_to imports_path, notice: t(".deleted")
  end

  private
    def import_exclusion_params
      params.require(:import_exclusion).permit(:name)
    end

    def apply_retroactively?
      ActiveModel::Type::Boolean.new.cast(params[:delete_existing])
    end
end
