source "https://rubygems.org"

git_source(:github) {|repo_name| "https://github.com/#{repo_name}" }

gemspec

gem "rake", "~> 13.0"

group :test do
  gem "rspec", "~> 3.0"
  gem "rantly"
  # GFC64::Model specs (skipped on older Rubies, where these don't install).
  if RUBY_VERSION >= "3.0"
    gem "activerecord"
    gem "sqlite3"
  end
  # Optional: GFC64_PG_URL=postgres://... runs the real-sequence spec.
  gem "pg" if ENV["GFC64_PG_URL"]
end
