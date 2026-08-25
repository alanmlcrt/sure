class ImportExclusionsController < ApplicationController
  def index
    @import_exclusions = Current.family.import_exclusions.order(:name)
    @import_exclusion = ImportExclusion.new

    render layout: "settings"
  end

  def create
    @import_exclusion = Current.family.import_exclusions.new(import_exclusion_params)

    if @import_exclusion.save
      redirect_to import_exclusions_path, notice: t(".created")
    else
      redirect_to import_exclusions_path, alert: @import_exclusion.errors.full_messages.to_sentence
    end
  end

  def destroy
    Current.family.import_exclusions.find(params[:id]).destroy!
    redirect_to import_exclusions_path, notice: t(".deleted")
  end

  private
    def import_exclusion_params
      params.require(:import_exclusion).permit(:name)
    end
end
