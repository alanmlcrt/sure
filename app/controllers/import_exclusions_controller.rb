class ImportExclusionsController < ApplicationController
  def create
    @import_exclusion = Current.family.import_exclusions.new(import_exclusion_params)

    if @import_exclusion.save
      redirect_to imports_path, notice: t(".created")
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
end
