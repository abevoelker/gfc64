# frozen_string_literal: true

class GFC64
  # App-wide key for the Rails helpers (GFC64::Model). Read on first use, not
  # at boot, so asset builds and consoles without the secret still start.
  #
  #   GFC64.configure { |c| c.key = Rails.application.credentials.gfc64_key }
  #
  # Without configure, ENV["GFC64_KEY"] is used. The key is 64 hex
  # characters (GFC64.generate_key): the Feistel cipher uses it as given,
  # FF1 as the 32 bytes it encodes (AES-256).
  class Config
    attr_writer :key

    def key
      k = @key.respond_to?(:call) ? @key.call : @key
      k = ENV["GFC64_KEY"] if k.nil? || k.empty?
      if k.nil? || k.empty?
        raise KeyMissing, "GFC64 has no key: set GFC64_KEY or GFC64.configure { |c| c.key = ... } " \
                          "(make one with GFC64.generate_key)"
      end
      unless k.match?(/\A\h{64}\z/)
        raise ArgumentError, "the GFC64 key must be 64 hex characters (GFC64.generate_key)"
      end

      k
    end

    # Test-only escape hatch for published example keys (see GFC64::Keys).
    attr_accessor :insecure_test_key
  end

  class KeyMissing < StandardError; end

  def self.config
    @config ||= Config.new
  end

  def self.configure
    yield config
    reset_ciphers!
    config
  end

  # Ciphers are built once per model on first use; this drops them (after
  # configure, or in tests that change the key).
  def self.reset_ciphers!
    @cipher_generation = cipher_generation + 1
  end

  def self.cipher_generation
    @cipher_generation ||= 0
  end
end
