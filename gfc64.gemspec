# -*- encoding: utf-8 -*-
# frozen_string_literal: true

$:.push File.expand_path("../lib", __FILE__)
require "gfc64"

Gem::Specification.new do |s|
  s.name        = "gfc64"
  s.version     = GFC64::VERSION.dup
  s.platform    = Gem::Platform::RUBY
  s.licenses    = ["MIT"]
  s.summary     = "Generalized Feistel Cipher for 64-bit integers"
  s.email       = "abe@abevoelker.com"
  s.homepage    = "https://github.com/abevoelker/gfc64"
  s.description = "Hides sequential primary key counts without resorting to UUIDs or GUIDs: a Feistel cipher over 16-64 bit integers, NIST SP 800-38G FF1, and short-code formatters (Crockford base32, base58)."
  s.authors     = ["Abe Voelker"]
  s.metadata    = {
    "homepage_uri"      => "https://github.com/abevoelker/gfc64",
    "documentation_uri" => "https://rubydoc.info/github/abevoelker/gfc64",
    "source_code_uri"   => "https://github.com/abevoelker/gfc64",
    "bug_tracker_uri"   => "https://github.com/abevoelker/gfc64/issues"
  }

  s.files         = Dir["{app,config,lib,sql}/**/*", "README.md", "CHANGELOG.md"]
  s.require_paths = ["lib"]
  s.required_ruby_version = '>= 2.4.0'
end
