# frozen_string_literal: true

require "openssl"

class GFC64
  # FF1 format-preserving encryption, NIST SP 800-38G (Algorithms 7 and 8):
  # encrypts a string of `length` digits in base `radix` into another string
  # of the same length and base, with AES (128, 192 or 256-bit key) and an
  # optional tweak. Checked against NIST's published FF1 sample vectors.
  #
  #   ff1 = GFC64::FF1.new(key_bytes, radix: 32, length: 8, tweak: "invoices")
  #   code = ff1.encrypt(42)   # => an Integer below 32**8
  #   ff1.decrypt(code)        # => 42
  #
  # Pair it with GFC64::Format (e.g. Crockford32.new(length: 8)) for codes.
  class FF1
    ROUNDS = 10
    # SP 800-38G Rev. 1 requires radix**minlen >= 1,000,000.
    MIN_DOMAIN = 1_000_000
    MAX_RADIX = 65_536

    attr_reader :radix, :length, :tweak

    # key:    the AES key as raw bytes (16, 24 or 32 bytes); for hex,
    #         [hex].pack("H*")
    # radix:  the base of each digit, 2 to 65,536
    # length: digits per value when using encrypt/decrypt on Integers
    #         (encrypt_digits takes any length the domain rule allows)
    # tweak:  public bytes that select an independent permutation (default "")
    def initialize(key, radix:, length: nil, tweak: "")
      key = key.b
      raise ArgumentError, "key must be 16, 24 or 32 bytes (AES-128/192/256)" unless [16, 24, 32].include?(key.bytesize)
      raise ArgumentError, "radix must be an Integer from 2 to #{MAX_RADIX}" unless radix.is_a?(Integer) && radix.between?(2, MAX_RADIX)

      @radix = radix
      @tweak = check_tweak(tweak)
      @length = length
      check_length!(length) unless length.nil?
      @cipher_name = "AES-#{key.bytesize * 8}-ECB"
      @key = key
    end

    # Integer in, Integer out: 0 <= number < radix**length.
    def encrypt(number, tweak: nil)
      from_digits(encrypt_digits(to_digits(number), tweak: tweak))
    end

    def decrypt(number, tweak: nil)
      from_digits(decrypt_digits(to_digits(number), tweak: tweak))
    end

    # Digit arrays (each 0...radix, most significant first), as in the standard.
    def encrypt_digits(x, tweak: nil)
      feistel(x, tweak.nil? ? @tweak : check_tweak(tweak), :encrypt)
    end

    def decrypt_digits(x, tweak: nil)
      feistel(x, tweak.nil? ? @tweak : check_tweak(tweak), :decrypt)
    end

    # The number of values (radix**length).
    def domain_size
      raise ArgumentError, "no length: given" if length.nil?

      radix**length
    end

    private

    def feistel(x, t, direction)
      check_digits!(x)
      n = x.size
      u = n / 2
      v = n - u
      a = x[0, u]
      b = x[u, v]
      bb = byte_len(v) # b in the standard
      d = 4 * ((bb + 3) / 4) + 4
      p_block = [1, 2, 1].pack("C3") + int_bytes(radix, 3) + [10, u % 256].pack("C2") + [n, t.bytesize].pack("N2")
      pad = "\0".b * ((-t.bytesize - bb - 1) % 16)
      aes = new_aes

      if direction == :encrypt
        ROUNDS.times do |i|
          y = round_value(aes, p_block, t, pad, i, num(b), bb, d)
          m = i.even? ? u : v
          c = (num(a) + y) % radix**m
          a, b = b, str(c, m)
        end
      else
        (ROUNDS - 1).downto(0) do |i|
          y = round_value(aes, p_block, t, pad, i, num(a), bb, d)
          m = i.even? ? u : v
          c = (num(b) - y) % radix**m
          b, a = a, str(c, m)
        end
      end
      a + b
    end

    # Steps 6.i-6.iv: Q, R = PRF(P || Q), S, y.
    def round_value(aes, p_block, t, pad, i, half_num, bb, d)
      q = t + pad + [i].pack("C") + int_bytes(half_num, bb)
      r = prf(aes, p_block + q)
      s = r.dup
      j = 1
      while s.bytesize < d
        s << ciph(aes, xor16(r, int_bytes(j, 16)))
        j += 1
      end
      s[0, d].unpack1("H*").to_i(16)
    end

    # CBC-MAC with a zero IV (the standard's PRF).
    def prf(aes, data)
      y = "\0".b * 16
      (0...data.bytesize).step(16) { |o| y = ciph(aes, xor16(y, data[o, 16])) }
      y
    end

    def ciph(aes, block)
      aes.update(block)
    end

    def new_aes
      aes = OpenSSL::Cipher.new(@cipher_name).encrypt
      aes.key = @key
      aes.padding = 0
      aes
    end

    def xor16(a, b)
      a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack("C*")
    end

    # b = ceil(ceil(v * log2(radix)) / 8), without floating point:
    # ceil(log2(N)) is the bit length of N - 1.
    def byte_len(v)
      ((radix**v - 1).bit_length + 7) / 8
    end

    def int_bytes(x, len)
      return "".b if len.zero?

      [x.to_s(16).rjust(len * 2, "0")].pack("H*")
    end

    def num(digits)
      digits.reduce(0) { |acc, dgt| acc * radix + dgt }
    end

    def str(x, m)
      out = Array.new(m, 0)
      (m - 1).downto(0) { |i| x, out[i] = x.divmod(radix) }
      out
    end

    def to_digits(number)
      raise ArgumentError, "no length: given; use encrypt_digits" if length.nil?
      unless number.is_a?(Integer) && number.between?(0, radix**length - 1)
        raise ArgumentError, "Number must be from 0 to #{radix**length - 1} (#{length} base-#{radix} digits)"
      end

      str(number, length)
    end

    def from_digits(digits)
      num(digits)
    end

    def check_tweak(tweak)
      raise ArgumentError, "tweak must be a String" unless tweak.is_a?(String)

      tweak.b.freeze
    end

    def check_length!(len)
      raise ArgumentError, "length must be an Integer of at least 2" unless len.is_a?(Integer) && len >= 2
      raise ArgumentError, "radix**length must be at least #{MIN_DOMAIN} (SP 800-38G)" if radix**len < MIN_DOMAIN
    end

    def check_digits!(x)
      raise ArgumentError, "expected an Array of digits" unless x.is_a?(Array)

      check_length!(x.size)
      return if x.all? { |dgt| dgt.is_a?(Integer) && dgt.between?(0, radix - 1) }

      raise ArgumentError, "every digit must be an Integer from 0 to #{radix - 1}"
    end
  end
end
