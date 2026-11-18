# frozen_string_literal: true

require "securerandom"

class GFC64
  # The key is what makes encrypted values unpredictable: two apps with the
  # same tweak but their own random keys get unrelated sequences. A key copied
  # from documentation or test vectors makes every value computable by anyone,
  # so those are refused unless a test says otherwise.
  module Keys
    README_KEY = "ffb5e3600fc27924f97dc055440403b10ce97160261f2a87eee576584cf942e5"
    NIST_FF1_KEYS = %w[
      2B7E151628AED2A6ABF7158809CF4F3C
      2B7E151628AED2A6ABF7158809CF4F3CEF4359D8D580AA4F
      2B7E151628AED2A6ABF7158809CF4F3CEF4359D8D580AA4F7F036D6F04FC6A94
    ].freeze
    KNOWN_HEX = ([README_KEY] + NIST_FF1_KEYS).map(&:downcase).freeze
    KNOWN_RAW = KNOWN_HEX.map { |h| [h].pack("H*") }.freeze

    module_function

    def check!(key, insecure_test_key)
      return if insecure_test_key

      raw = key.b
      reason =
        if KNOWN_HEX.include?(raw.downcase) || KNOWN_RAW.include?(raw)
          "is a published example key (README or NIST test vectors)"
        elsif raw.bytes.uniq.size <= 2
          "isn't random (it repeats one or two bytes)"
        end
      return unless reason

      raise ArgumentError, "This key #{reason}, so anyone could compute every value. " \
                           "Generate one with GFC64.generate_key or GFC64::FF1.generate_key and keep it secret; " \
                           "in tests, pass insecure_test_key: true."
    end
  end

  # A random key for GFC64.new, as 64 hex characters (fine in an env var).
  def self.generate_key
    SecureRandom.hex(32)
  end
end
