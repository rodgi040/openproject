# frozen_string_literal: true

module Flightplan
  # OP#2841: Der Menüpunkt „Research“ zeigt auf diese Route und leitet auf die Arbeitspaketliste des Projekts um, gefiltert
  # auf den Typ Recherche. Die Liste ist der Index; es gibt keine eigene Seite.
  class ResearchController < ApplicationController
    load_and_authorize_with_permission_in_project :view_work_packages

    def show
      type_id = Research.type_id
      if type_id.nil? || !@project.types.exists?(id: type_id)
        flash[:notice] = t("flightplan.research.missing_type")
        return redirect_to project_work_packages_path(@project)
      end

      redirect_to project_work_packages_path(@project, query_props: Research.query_props(type_id).to_json)
    end
  end
end
