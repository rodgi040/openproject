# frozen_string_literal: true

module Flightplan
  module WikiPages
    module_function

    def list(project, user)
      raise Error, "Wiki nicht sichtbar" unless user.allowed_in_project?(:view_wiki_pages, project)

      wiki = project.wiki
      return [] unless wiki

      wiki.pages.visible(user).order(:title).map { |page| { title: page.title, slug: page.slug } }
    end

    def read(project, title, user)
      page = find_visible!(project, title, user)
      payload(page)
    end

    def write(project, title, text, user)
      raise Error, "Wiki nicht beschreibbar" unless user.allowed_in_project?(:edit_wiki_pages, project)

      wiki = project.wiki || Wiki.create!(project:, start_page: title)
      page = wiki.pages.find_by(title:) || wiki.find_page(title)
      page ||= WikiPage.new(wiki:, title:, author: user)
      previous = User.current
      User.current = user
      page.text = text.to_s
      page.author ||= user
      page.save!
      payload(page.reload)
    ensure
      User.current = previous if defined?(previous)
    end

    def find_visible!(project, title, user)
      raise Error, "Wiki nicht sichtbar" unless user.allowed_in_project?(:view_wiki_pages, project)

      wiki = project.wiki
      raise Error, "Wiki-Seite fehlt" unless wiki

      page = wiki.pages.find_by(title:) || wiki.find_page(title)
      raise Error, "Wiki-Seite fehlt" unless page&.visible?(user)

      page
    end

    def payload(page)
      {
        title: page.title,
        text: page.text.to_s,
        author: page.journals.order(:version).last&.user&.login || page.author&.login,
        updated_at: page.updated_at&.iso8601
      }
    end
  end
end
