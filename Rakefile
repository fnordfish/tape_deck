# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

# Gem -> the Sequel adapter that uses it, which is also the scheme of its database URLs
MYSQL_ADAPTERS = {"mysql2" => "mysql2", "trilogy" => "trilogy", "ruby-mysql" => "mysql"}.freeze

namespace :spec do
  desc "Run the specs that need no database server, on SQLite"
  RSpec::Core::RakeTask.new(:sqlite) do |t|
    # Quoted, because the command runs through a shell, where ~name expands to the home directory of a user with that
    # name, if there is one. GitHub's runners have a "mysql" user, for example.
    t.rspec_opts = "--tag '~server'"
  end

  MYSQL_ADAPTERS.each do |gem_name, adapter|
    desc "Run the MySQL specs with #{gem_name}, needs TAPE_DECK_MYSQL_URL"
    task gem_name do
      server_url = ENV.fetch("TAPE_DECK_MYSQL_URL") { abort "Set TAPE_DECK_MYSQL_URL, see DEVELOPMENT.md" }
      adapter_url = server_url.sub(%r{\A\w+://}, "#{adapter}://")
      sh({"TAPE_DECK_MYSQL_URL" => adapter_url}, "rspec", "--tag", "server:mysql")
    end
  end

  desc "Run the PostgreSQL specs, needs TAPE_DECK_POSTGRES_URL"
  task :postgres do
    ENV.fetch("TAPE_DECK_POSTGRES_URL") { abort "Set TAPE_DECK_POSTGRES_URL, see DEVELOPMENT.md" }
    sh "rspec", "--tag", "server:postgres"
  end
end

desc "Run all specs, the database server ones if their URL is set (MySQL with every adapter)"
task :spec do
  Rake::Task["spec:sqlite"].invoke
  if ENV["TAPE_DECK_MYSQL_URL"]
    MYSQL_ADAPTERS.each_key { Rake::Task["spec:#{_1}"].invoke }
  else
    warn "Skipping the MySQL specs, TAPE_DECK_MYSQL_URL is not set"
  end
  if ENV["TAPE_DECK_POSTGRES_URL"]
    Rake::Task["spec:postgres"].invoke
  else
    warn "Skipping the PostgreSQL specs, TAPE_DECK_POSTGRES_URL is not set"
  end
end

require "standard/rake"

task default: %i[spec standard docs:check]

GEM_COOP_HOST = "https://gem.coop/@fnordfish"

namespace :release do
  desc "Push the built gem to #{GEM_COOP_HOST}, needs GEM_COOP_API_KEY"
  task gem_coop: :build do
    api_key = ENV.fetch("GEM_COOP_API_KEY") { abort "Set GEM_COOP_API_KEY to a push key from https://gem.coop/user/push_keys/new" }
    gem_file = "pkg/#{Bundler::GemHelper.gemspec.full_name}.gem"

    # Only this push gets the key, so it is never sent to rubygems.org
    sh({"GEM_HOST_API_KEY" => api_key}, "gem", "push", gem_file, "--host", GEM_COOP_HOST)
  end
end

namespace :docs do
  desc "Build the YARD docs of the working tree, and check that every link between their pages and anchors works"
  task :check do
    require "cgi"
    output = File.expand_path("tmp/docs-check")
    rm_rf output
    sh "yard", "doc", "--no-save", "--no-stats", "--quiet", "--output-dir", output

    pages = Dir.glob("#{output}/**/*.html").reject { File.basename(_1).match?(/\A(class_list|method_list|file_list|frames)\.html\z/) }
    ids = Hash.new { |cache, page| cache[page] = File.read(page).scan(/\bid="([^"]+)"/).flatten }
    broken = pages.flat_map do |page|
      File.read(page).scan(/href="([^"]+)"/).flatten.filter_map do |href|
        next if href == "#" || href.match?(%r{\A[a-z]+:}) # external links are not checked

        path, anchor = href.split("#", 2)
        target = path.empty? ? page : File.expand_path(path, File.dirname(page))
        problem = if !File.exist?(target)
          "missing page"
        elsif anchor && !anchor.empty? && !ids[target].include?(CGI.unescape(anchor))
          "missing anchor"
        end
        "#{page.delete_prefix("#{output}/")}: #{href} (#{problem})" if problem
      end
    end.uniq
    abort "Broken links in the docs:\n#{broken.join("\n")}" unless broken.empty?
    puts "All links in the docs work"
  end

  desc "Build the YARD docs of main and every version tag into _site, like GitHub Pages publishes them"
  task :pages do
    # Start from scratch, also after an interrupted run left worktrees behind
    rm_rf %w[_site tmp/pages]
    sh "git", "worktree", "prune"

    version = ->(tag) { Gem::Version.new(tag.delete_prefix("v")) }
    tags = `git tag --list "v*"`.split.select { Gem::Version.correct?(_1.delete_prefix("v")) }
    tags = tags.sort_by(&version).reverse
    refs = ["main", *tags]

    refs.each do |ref|
      # Without a local main branch (e.g. CI building a tag), use the remote one
      commit = ref
      commit = "origin/#{ref}" if ref == "main" && !system("git", "rev-parse", "--verify", "--quiet", ref, out: File::NULL)
      worktree = File.expand_path("tmp/pages/#{ref}")
      output = File.expand_path("_site/docs/#{ref}")

      sh "git", "worktree", "add", "--detach", worktree, commit
      begin
        Dir.chdir(worktree) do
          sh "yard", "doc", "--no-save", "--no-stats", "--title", "TapeDeck #{ref}", "--output-dir", output
        end
      ensure
        sh "git", "worktree", "remove", "--force", worktree
      end
    end

    # The newest release, or the newest prerelease until there is one
    latest = tags.find { !version.call(_1).prerelease? } || tags.first || "main"
    links = refs.map do |ref|
      link = %(<a href="#{ref}/">#{ref}</a>)
      link += " (latest)" if ref == latest
      "<li>#{link}</li>"
    end
    File.write("_site/docs/index.html", <<~HTML)
      <!DOCTYPE html>
      <html><head><meta charset="utf-8"><title>TapeDeck docs</title></head>
      <body><h1>TapeDeck docs</h1><ul>
      #{links.join("\n")}
      </ul></body></html>
    HTML
    mkdir_p "_site/docs/latest"
    File.write("_site/docs/latest/index.html", <<~HTML)
      <!DOCTYPE html>
      <html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=../#{latest}/"></head></html>
    HTML
    File.write("_site/index.html", <<~HTML)
      <!DOCTYPE html>
      <html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=docs/"></head></html>
    HTML
  end
end

Rake::Task["release"].enhance { Rake::Task["release:gem_coop"].invoke }
