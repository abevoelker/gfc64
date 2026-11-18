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

      # alphabet:       the characters, lowest value first
      # bits:           the width of the numbers (match GFC64's bits:)
      # case_sensitive: false folds input to the alphabet's case
      # aliases:        extra input characters read as another, e.g. "O" => "0"
      # group:          on output, put `separator` every `group` characters
      # ignore:         input characters dropped before decoding (spaces and
      #                 hyphens by default; the separator always is)
      def initialize(alphabet, bits:, case_sensitive: true, aliases: {}, group: nil, separator: "-", ignore: " -")
        chars = alphabet.chars
        raise ArgumentError, "alphabet needs at least 2 distinct characters" if chars.uniq.size != chars.size || chars.size < 2
        raise ArgumentError, "bits must be a positive Integer" unless bits.is_a?(Integer) && bits.positive?
        raise ArgumentError, "group must be a positive Integer" unless group.nil? || (group.is_a?(Integer) && group.positive?)

        @alphabet = alphabet.dup.freeze
        @chars = chars.freeze
        @base = chars.size
        @bits = bits
        @max = (1 << bits) - 1
        @length = 1
        @length += 1 while @base**@length <= @max
        @case_sensitive = case_sensitive
        @group = group
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
          raise ArgumentError, "Number must be a #{bits}-bit integer (0 to #{@max})"
        end

        out = Array.new(@length, @chars[0])
        i = @length - 1
        while number.positive?
          number, digit = number.divmod(@base)
          out[i] = @chars[digit]
          i -= 1
        end
        s = out.join
        group ? s.scan(/.{1,#{group}}/).join(separator) : s
      end

      def decode(string)
        raise ArgumentError, "expected a String" unless string.is_a?(String)

        s = @ignore ? string.gsub(@ignore, "") : string
        raise ArgumentError, "expected #{@length} characters, got #{s.length}" unless s.length == @length

        number = s.each_char.reduce(0) do |acc, c|
          digit = @values[fold(c)]
          raise ArgumentError, "#{c.inspect} isn't a valid character" if digit.nil?

          acc * @base + digit
        end
        raise ArgumentError, "#{string.inspect} is out of range for #{bits} bits" if number > @max

        number
      end

      # True when the string decodes (right length, characters and range).
      def valid?(string)
        decode(string)
        true
      rescue ArgumentError
        false
      end

      private

      def fold(c)
        @case_sensitive ? c : c.upcase
      end
    end

    # Douglas Crockford's base32 (https://www.crockford.com/base32.html):
    # digits and capitals without I, L, O, U. Input is forgiving: any case,
    # O reads as 0, I and L as 1, hyphens and spaces ignored. 40 bits is
    # exactly 8 characters.
    class Crockford32 < Alphabet
      ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

      def initialize(bits:, group: nil, separator: "-")
        super(ALPHABET, bits: bits, case_sensitive: false, aliases: { "O" => "0", "I" => "1", "L" => "1" },
                        group: group, separator: separator)
      end
    end

    # Bitcoin's base58: digits and both cases without 0, O, I, l. Shorter than
    # base32 (40 bits is 7 characters) but case-sensitive, so better for links
    # and QR codes than for reading aloud.
    class Base58 < Alphabet
      ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

      def initialize(bits:, group: nil, separator: "-")
        super(ALPHABET, bits: bits, group: group, separator: separator)
      end
    end

    # Plain digits, zero-padded (40 bits is 13 digits), e.g. for phone keypads.
    class Decimal < Alphabet
      def initialize(bits:, group: nil, separator: "-")
        super("0123456789", bits: bits, group: group, separator: separator)
      end
    end
  end
end
