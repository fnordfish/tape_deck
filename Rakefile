# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

MYSQL_ADAPTERS = %w[mysql2 trilogy].freeze

namespace :spec do
  desc "Run the specs that need no MySQL server"
  RSpec::Core::RakeTask.new(:fake) do |t|
    # Quoted, because the command runs through a shell, and where a "mysql" user exists (GitHub's runners), ~mysql
    # expands to its home directory
    t.rspec_opts = "--tag '~mysql'"
  end

  MYSQL_ADAPTERS.each do |adapter|
    desc "Run the MySQL specs with #{adapter}, needs TAPE_DECK_MYSQL_URL"
    task adapter do
      server_url = ENV.fetch("TAPE_DECK_MYSQL_URL") { abort "Set TAPE_DECK_MYSQL_URL, see DEVELOPMENT.md" }
      adapter_url = server_url.sub(%r{\A\w+://}, "#{adapter}://")
      sh({"TAPE_DECK_MYSQL_URL" => adapter_url}, "rspec", "--tag", "mysql")
    end
  end
end

desc "Run all specs, the MySQL ones with every adapter if TAPE_DECK_MYSQL_URL is set"
task :spec do
  Rake::Task["spec:fake"].invoke
  if ENV["TAPE_DECK_MYSQL_URL"]
    MYSQL_ADAPTERS.each { Rake::Task["spec:#{_1}"].invoke }
  else
    warn "Skipping the MySQL specs, TAPE_DECK_MYSQL_URL is not set"
  end
end

require "standard/rake"

task default: %i[spec standard]

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
