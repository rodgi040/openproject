# frozen_string_literal: true

module OpenProject::Flightplan
  class Hooks < OpenProject::Hook::ViewListener
    render_on :view_layouts_base_body_bottom, partial: "flightplan/hooks/body_bottom"
  end
end
