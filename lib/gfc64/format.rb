# frozen_string_literal: true

class GFC64
  # Turn encrypted numbers into short strings people can read and type, and
  # back. Every formatter is fixed-length for its width, so codes line up and a
  # missing or extra character is caught instead of silently decoding to some
  # other number.
  #
  #   gfc = GFC64.new(key, bits: 40)
  #   fmt = GFC64::Format::Crockford32.new(bits: 40, group: 4)
  #   code = fmt.encode(gfc.encrypt(42)) # => "7KQM-R3XH"
  #   gfc.decrypt(fmt.decode("7kqm r3xh")) # => 42
  module Format
    # Any alphabet: the length is the fewest characters that can hold every
    # value of `bits` bits.
    class Alphabet
      attr_reader :alphabet, :bits, :length, :group, :separator

      # Raised by decode when a code's check character doesn't match: a typo
      # (any one wrong character, or two neighbours swapped), never a valid
      # code. An ArgumentError, so valid? and normalize treat it like any
      # other bad input.
      class CheckError < ArgumentError; end

      # Irreducible polynomials for GF(2^k), used by the check character.
      GF_POLYNOMIALS = { 2 => 0b111, 3 => 0b1011, 4 => 0b10011, 5 => 0b100101, 6 => 0b1000011,
                         7 => 0b10000011, 8 => 0b100011011 }.freeze

      # alphabet:       the characters, lowest value first
      # bits:           the width of the numbers (match GFC64's bits:), or
      # length:         a fixed number of characters (match FF1's length:
      #                 when FF1's radix is this alphabet's size)
      # case_sensitive: false folds input to the alphabet's case
      # aliases:        extra input characters read as another, e.g. "O" => "0"
      # group:          on output, put `separator` every `group` characters,
      #                 or an Array of group sizes, e.g. [4, 5] (the last
      #                 size repeats for anything longer)
      # check:          true appends one check character (alphabets of 4 to
      #                 256 characters, a power of two). It catches every
      #                 single wrong character and every swap of two
      #                 neighbours, and it's from the alphabet itself.
      # ignore:         input characters dropped before decoding (spaces and
      #                 hyphens by default; the separator always is)
      def initialize(alphabet, bits: nil, length: nil, case_sensitive: true, aliases: {}, group: nil, separator: "-", ignore: " -",
                     check: false)
        chars = alphabet.chars
        raise ArgumentError, "alphabet needs at least 2 distinct characters" if chars.uniq.size != chars.size || chars.size < 2
        raise ArgumentError, "give exactly one of bits: or length:" unless bits.nil? ^ length.nil?
        raise ArgumentError, "bits must be a positive Integer" unless bits.nil? || (bits.is_a?(Integer) && bits.positive?)
        raise ArgumentError, "length must be a positive Integer" unless length.nil? || (length.is_a?(Integer) && length.positive?)
        groups = group.is_a?(Array) ? group : [group].compact
        unless groups.all? { |g| g.is_a?(Integer) && g.positive? } && (group.nil? || !groups.empty?)
          raise ArgumentError, "group must be a positive Integer or an Array of them"
        end
        if check && !(chars.size & (chars.size - 1)).zero? || check && !GF_POLYNOMIALS.key?(chars.size.bit_length - 1)
          raise ArgumentError, "check: needs an alphabet of 4 to 256 characters, a power of two (this one has #{chars.size})"
        end

        @alphabet = alphabet.dup.freeze
        @chars = chars.freeze
        @base = chars.size
        if bits
          @bits = bits
          @max = (1 << bits) - 1
          @length = 1
          @length += 1 while @base**@length <= @max
        else
          @length = length
          @max = @base**length - 1
          @bits = @max.bit_length
        end
        @case_sensitive = case_sensitive
        @group = group.is_a?(Array) ? group.dup.freeze : group
        @groups = groups.freeze
        @check = check ? true : false
        if @check
          @gf_bits = @base.bit_length - 1
          @gf_poly = GF_POLYNOMIALS.fetch(@gf_bits)
        end
        @separator = separator
        dropped = (ignore.to_s + separator.to_s).chars.uniq - chars
        @ignore = dropped.empty? ? nil : /[#{Regexp.escape(dropped.join)}]/
        @values = {}
        chars.each_with_index { |c, i| @values[fold(c)] = i }
        aliases.each do |from, to|
          raise ArgumentError, "alias target #{to.inspect} isn't in the alphabet" unless @values.key?(fold(to))

          @values[fold(from)] = @values[fold(to)]
        end
      end

      def encode(number)
        unless number.is_a?(Integer) && number.between?(0, @max)
          raise ArgumentError, "Number must be from 0 to #{@max}"
        end

        out = Array.new(@length, @chars[0])
        i = @length - 1
        while number.positive?
          number, digit = number.divmod(@base)
          out[i] = @chars[digit]
          i -= 1
        end
        out << @chars[check_digit(out.map { |c| @values[fold(c)] })] if @check
        grouped(out.join)
      end

      # True when codes end in a check character.
      def check?
        @check
      end

      # Characters in a code, counting the check character but not separators.
      def code_length
        @length + (@check ? 1 : 0)
      end

      # strict: true accepts only the exact canonical form (what encode
      # returns: its case, its separators, no look-alikes or extra spaces),
      # e.g. for input from machines. The default forgives what the alphabet
      # safely can, for input from people.
      def decode(string, strict: false)
        number = lenient_decode(string)
        if strict && (canonical = encode(number)) != string
          raise ArgumentError, "#{string[0, 64].inspect} isn't in canonical form (#{canonical.inspect})"
        end

        number
      end

      # The canonical form of a code however it was typed, or nil when it
      # isn't one: normalize("tcnh r99b") => "TCNH-R99B" (with group: 4).
      def normalize(string)
        encode(lenient_decode(string))
      rescue ArgumentError
        nil
      end

      # True when the string is exactly the canonical form.
      def canonical?(string)
        !string.nil? && normalize(string) == string
      end

      private def lenient_decode(string)
        raise ArgumentError, "expected a String" unless string.is_a?(String)

        s = @ignore ? string.gsub(@ignore, "") : string
        raise ArgumentError, "expected #{code_length} characters, got #{s.length}" unless s.length == code_length

        digits = s.each_char.map do |c|
          digit = @values[fold(c)]
          raise ArgumentError, "#{c.inspect} isn't a valid character" if digit.nil?

          digit
        end
        if @check
          raise CheckError, "#{string[0, 64].inspect} has a typo (its check character doesn't match)" unless damm(digits).zero?

          digits.pop
        end
        number = digits.reduce(0) { |acc, d| acc * @base + d }
        raise ArgumentError, "#{string.inspect} is out of range (above #{@max})" if number > @max

        number
      end

      # The largest value a code can hold.
      attr_reader :max

      # The alphabet's size: pass it as FF1's radix:.
      def radix
        @base
      end

      # True when the string decodes (right length, characters and range).
      def valid?(string, strict: false)
        decode(string, strict: strict)
        true
      rescue ArgumentError
        false
      end

      private

      def fold(c)
        @case_sensitive ? c : c.upcase
      end

      def grouped(s)
        return s if @groups.empty?

        parts = []
        i = 0
        k = 0
        while i < s.length
          size = @groups[[k, @groups.size - 1].min]
          parts << s[i, size]
          i += size
          k += 1
        end
        parts.join(separator)
      end

      # Damm's algorithm over GF(2^k) with x * y = 2x + y: a weakly totally
      # anti-symmetric quasigroup, so any one changed digit or swap of two
      # neighbouring digits changes the result.
      def damm(digits)
        digits.reduce(0) { |acc, d| gf_double(acc) ^ d }
      end

      # The digit that brings the running Damm value to zero.
      def check_digit(digits)
        gf_double(damm(digits))
      end

      def gf_double(x)
        x <<= 1
        x ^= @gf_poly if x >= @base
        x
      end
    end

    # Douglas Crockford's base32 (https://www.crockford.com/base32.html):
    # digits and capitals without I, L, O, U. Input is forgiving: any case,
    # O reads as 0, I and L as 1, hyphens and spaces ignored. 40 bits is
    # exactly 8 characters.
    #
    # check: true adds a 9th character from the same 32 (not Crockford's own
    # mod-37 check symbols *~$=U, which are awkward in links and to read out).
    class Crockford32 < Alphabet
      ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

      def initialize(bits: nil, length: nil, group: nil, separator: "-", check: false)
        super(ALPHABET, bits: bits, length: length, case_sensitive: false, aliases: { "O" => "0", "I" => "1", "L" => "1" },
                        group: group, separator: separator, check: check)
      end
    end

    # Bitcoin's base58: digits and both cases without 0, O, I, l. Shorter than
    # base32 (40 bits is 7 characters) but case-sensitive, so better for links
    # and QR codes than for reading aloud.
    class Base58 < Alphabet
      ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

      def initialize(bits: nil, length: nil, group: nil, separator: "-")
        super(ALPHABET, bits: bits, length: length, group: group, separator: separator)
      end
    end

    # Plain digits, zero-padded (40 bits is 13 digits), e.g. for phone keypads.
    class Decimal < Alphabet
      def initialize(bits: nil, length: nil, group: nil, separator: "-")
        super("0123456789", bits: bits, length: length, group: group, separator: separator)
      end
    end
  end
end
