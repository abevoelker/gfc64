# frozen_string_literal: true

require "openssl"
require "securerandom"

class GFC64
  VERSION = "0.0.2".freeze

  attr_reader :rounds, :key, :block_size

  def initialize(key, rounds: 3)
    @key = key
    @block_size = 8 # 64 bits
    @rounds = rounds
  end

  def encrypt(number)
    raise ArgumentError, 'Number must be a 64-bit integer' unless number.is_a?(Integer) && number.between?(0, 2**64 - 1)

    # Split the number into two 32-bit halves
    left, right = number >> 32, number & 0xFFFFFFFF

    rounds.times do |round|
      round_key = derive_round_key(key, round)
      aes = OpenSSL::Cipher.new('AES-128-ECB').encrypt
      aes.key = round_key
      f = aes.update([right].pack('N')) + aes.final
      left, right = right, left ^ f.unpack1('N')
    end

    # Combine the two 32-bit halves back into a 64-bit number
    (left << 32) | right
  end

  def decrypt(number)
    raise ArgumentError, 'Number must be a 64-bit integer' unless number.is_a?(Integer) && number.between?(0, 2**64 - 1)

    left, right = number >> 32, number & 0xFFFFFFFF

    rounds.times do |round|
      round_key = derive_round_key(key, rounds - round - 1)
      aes = OpenSSL::Cipher.new('AES-128-ECB').encrypt
      aes.key = round_key
      f = aes.update([left].pack('N')) + aes.final
      left, right = right ^ f.unpack1('N'), left
    end

    (left << 32) | right
  end

  private

  def derive_round_key(key, round)
    # A simple round key derivation using SHA256 and the round number
    OpenSSL::Digest::SHA256.digest(key + [round].pack('L'))[0...16] # Truncate to 128 bits for AES key
  end
end
