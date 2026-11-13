# frozen_string_literal: true

# Loaded by .yardopts. Links between the Markdown pages (README.md, guide/*.md) point at .md files, which works on
# GitHub. YARD turns each page into file.<name>.html instead, so this rewrites relative .md links to those pages.
module MarkdownPageLinks
  RELATIVE_MD_LINK = %r{href="(?![a-z]+://)(?:[\w./-]*/)?([\w-]+)\.md(#[^"]*)?"}

  def html_markup_markdown(text)
    super.gsub(RELATIVE_MD_LINK) { %(href="file.#{$1}.html#{$2}") }
  end
end

YARD::Templates::Helpers::HtmlHelper.prepend(MarkdownPageLinks)
