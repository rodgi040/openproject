# frozen_string_literal: true

require_relative "lib/open_project/flightplan/version"

Gem::Specification.new do |s|
  s.name        = "openproject-flightplan"
  s.version     = OpenProject::Flightplan::VERSION
  s.authors     = "Flightplan"
  s.email       = "dev@localhost"
  s.summary     = "OpenProject Flightplan"
  s.description = "Flightplan module for the OpenProject fork"
  s.license     = "GPLv3"
  s.homepage    = "https://github.com/rodgi040/openproject"

  s.files = Dir["{app,config,db,lib}/**/*"]
  s.metadata["rubygems_mfa_required"] = "true"
end
