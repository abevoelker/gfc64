# -*- encoding: utf-8 -*-
# frozen_string_literal: true

$:.push File.expand_path("../lib", __FILE__)
require "gfc64"

Gem::Specification.new do |s|
  s.name        = "GFC64"
  s.version     = GFC64::VERSION.dup
  s.platform    = Gem::Platform::RUBY
  s.licenses    = ["MIT"]
  s.summary     = "Generalized Feistel Cipher for 64-bit integers"
  s.email       = "abe@abevoelker.com"
  s.homepage    = "https://github.com/abevoelker/gfc64"
  s.description = "Hides sequential primary key counts without resorting to UUIDs or GUIDs."
  s.authors     = ["Abe Voelker"]
  s.metadata    = {
    "homepage_uri"      => "https://github.com/abevoelker/gfc64",
    "documentation_uri" => "https://rubydoc.info/github/abevoelker/gfc64",
    "source_code_uri"   => "https://github.com/abevoelker/gfc64",
    "bug_tracker_uri"   => "https://github.com/abevoelker/gfc64/issues"
  }

  s.files         = Dir["{app,config,lib}/**/*", "README.md"]
  s.require_paths = ["lib"]
  s.required_ruby_version = '>= 2.1.0'
end
