# frozen_string_literal: true

require "openssl"
require "securerandom"

# A balanced Feistel cipher over the integers 0...2**bits: every value maps to
# exactly one other value of the same width, and back again with the same key.
class GFC64
  VERSION = "0.2.0".freeze

  MIN_BITS = 16
  MAX_BITS = 64
  # Narrower blocks have smaller halves, so they get more rounds by default
  # (NIST's FF1 format-preserving cipher uses 10). 64-bit keeps 3 so existing
  # encrypted values don't change.
  DEFAULT_ROUNDS = 3
  DEFAULT_NARROW_ROUNDS = 10

  attr_reader :rounds, :key, :block_size, :bits

  # bits: the width of the numbers encrypted, an even number from 16 to 64.
  # Every number from 0 to 2**bits - 1 encrypts to a different number in the
  # same range. The default (64) gives exactly the same results as 0.1.0.
  def initialize(key, rounds: nil, bits: MAX_BITS)
    unless bits.is_a?(Integer) && bits.even? && bits.between?(MIN_BITS, MAX_BITS)
      raise ArgumentError, "bits must be an even Integer from #{MIN_BITS} to #{MAX_BITS}"
    end

    @key = key
    @bits = bits
    @half_bits = bits / 2
    @half_mask = (1 << @half_bits) - 1
    @max = (1 << bits) - 1
    @block_size = bits % 8 == 0 ? bits / 8 : Rational(bits, 8) # in bytes
    @rounds = rounds || (bits == MAX_BITS ? DEFAULT_ROUNDS : DEFAULT_NARROW_ROUNDS)
    raise ArgumentError, "rounds must be a positive Integer" unless @rounds.is_a?(Integer) && @rounds.positive?

    @round_keys = Array.new(@rounds) { |round| derive_round_key(key, round) }
  end

  def encrypt(number)
    check!(number)

    left, right = number >> @half_bits, number & @half_mask

    rounds.times do |round|
      left, right = right, left ^ f(@round_keys[round], right)
    end

    (left << @half_bits) | right
  end

  def decrypt(number)
    check!(number)

    left, right = number >> @half_bits, number & @half_mask

    rounds.times do |round|
      left, right = right ^ f(@round_keys[rounds - round - 1], left), left
    end

    (left << @half_bits) | right
  end

  private

  def check!(number)
    return if number.is_a?(Integer) && number.between?(0, @max)

    raise ArgumentError, "Number must be a #{bits}-bit integer (0 to #{@max})"
  end

  # Round function: AES-128 of the half block, truncated to the half's width.
  def f(round_key, half)
    aes = OpenSSL::Cipher.new("AES-128-ECB").encrypt
    aes.key = round_key
    (aes.update([half].pack("N")) + aes.final).unpack1("N") & @half_mask
  end

  def derive_round_key(key, round)
    if bits == MAX_BITS
      # Unchanged from 0.1.0 so 64-bit values stay the same.
      OpenSSL::Digest::SHA256.digest(key + [round].pack("L"))[0...16]
    else
      # The width is part of the round key, so the same key at different
      # widths gives unrelated ciphers; "N" (big-endian) is portable.
      OpenSSL::Digest::SHA256.digest("#{key}\0gfc64\0bits=#{bits}\0" + [round].pack("N"))[0...16]
    end
  end
end

require "gfc64/active_record"
