# frozen_string_literal: true

source "https://rubygems.org"
gemspec

gem "rake"
gem "rspec", "~> 3.13"

group :development, :test do
  # The dummy app under spec/dummy exercises the ActiveRecord-backed adapters
  # against a real Postgres. None of this is a runtime dependency of the gem:
  # the core is plain Ruby and each adapter degrades when its gem is absent.
  gem "rails", ">= 7.1"
  gem "pg", ">= 1.5"
  gem "pgvector", ">= 0.2"
  gem "numo-narray"
  gem "pdf-reader"
  gem "rubyzip"
end
