# frozen_string_literal: true

# Loaded by .yardopts. The Markdown pages (README.md, guide/*.md) are written for GitHub, this makes them work in the
# YARD docs too.
module MarkdownPages
  # The published docs. Guide pages link to the API there, so the links work on GitHub as well.
  DOCS_URL = "https://fnordfish.github.io/tape_deck/docs/latest/"

  # Pages that are not part of the docs are linked on GitHub instead.
  REPO_URL = "https://github.com/fnordfish/tape_deck/blob/main/"

  RELATIVE_MD_LINK = %r{href="(?![a-z]+://)([\w./-]*?)([\w-]+)\.md(#[^"]*)?"}
  DOCS_LINK = %r{href="#{Regexp.escape(DOCS_URL)}([^"]*)"}

  # Labels pages with their first heading in the file list, instead of their file name
  module Title
    def title
      attributes[:title] || contents[/\A#\s+(.+)$/, 1]&.strip || super
    end
  end

  # Rewrites links between Markdown pages to the pages YARD generates for them, and links into the published API
  # docs to the API of the docs being built, so each version links to its own.
  module Links
    def html_markup_markdown(text)
      super
        .gsub(DOCS_LINK) { %(href="#{$1}") }
        .gsub(RELATIVE_MD_LINK) { %(href="#{page_url($1, $2, $3)}") }
    end

    private

    def page_url(dir, name, anchor)
      published = Array(options.files).map(&:name) | [options.readme&.name].compact
      return "file.#{name}.html#{anchor}" if published.include?(name)

      current_dir = File.dirname(options.file&.filename.to_s)
      path = File.expand_path(File.join(current_dir, "#{dir}#{name}.md"), "/").delete_prefix("/")
      # A link to a file that doesn't exist stays a link to a missing page, so rake docs:check reports it
      return "file.#{name}.html#{anchor}" unless File.exist?(path)

      "#{REPO_URL}#{path}#{anchor}"
    end
  end
end

YARD::CodeObjects::ExtraFileObject.prepend(MarkdownPages::Title)
YARD::Templates::Helpers::HtmlHelper.prepend(MarkdownPages::Links)
