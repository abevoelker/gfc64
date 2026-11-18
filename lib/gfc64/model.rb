# frozen_string_literal: true

class GFC64
  # ActiveRecord helpers. In Rails every model has them; elsewhere,
  # `include GFC64::Model`.
  #
  #   class Customer < ApplicationRecord
  #     has_public_id bits: 40, format: GFC64::Format::Base58.new(bits: 40)
  #   end
  #   customer_path(customer)                  # => "/customers/BQZbwjf"
  #   Customer.find_by_public_id!(params[:id]) # bad or unknown => RecordNotFound
  #
  #   class Invoice < ApplicationRecord
  #     has_code :number, sequence: "invoice_numbers", prefix: "APP-",
  #                       format: GFC64::Format::Crockford32.new(length: 8, group: 4)
  #   end
  #   Invoice.create!.number                          # => "APP-TCNH-R99B"
  #   Invoice.find_by_code!(:number, "blm tcnh-r99b") # any case, spacing, O/I/L
  module Model
    def self.included(base)
      base.extend(ClassMethods)
    end

    # Raised by the bang finders; ActiveRecord::RecordNotFound when available,
    # so Rails answers 404.
    def self.not_found_error
      defined?(::ActiveRecord::RecordNotFound) ? ::ActiveRecord::RecordNotFound : KeyError
    end

    module ClassMethods
      # The primary key, encrypted for URLs; nothing is stored.
      #
      # bits:   width of the cipher (IDs must stay below 2**bits); 64 by default
      # format: a GFC64::Format to show it (default: the plain number)
      # cipher: :feistel (default) or :ff1 (needs a length:-based format;
      #         its radix and length set the domain)
      # tweak:  defaults to the table name, so each model gets its own mapping;
      #         false for none (the same numbers as the 0.1.0 mixin)
      # param:  false keeps to_param as the plain id
      def has_public_id(bits: 64, format: nil, cipher: :feistel, tweak: nil, param: true)
        opts = { bits: bits, format: format, cipher: cipher, tweak: tweak }
        GFC64::Model.check_options!(opts, :has_public_id)
        @gfc64_public_id = opts
        include PublicIdMethods
        define_method(:to_param) { public_id } if param
      end

      # A code stored in `column`, made on create from the next value of a
      # database sequence: encrypted (FF1 by default), formatted, prefixed.
      #
      # sequence: a Postgres sequence name, or a callable returning the next
      #           Integer (other databases, tests)
      # format:   a GFC64::Format (required)
      # prefix:   added in front, e.g. "APP-"; optional when looking up
      # cipher:   :ff1 (default; any alphabet) or :feistel (power-of-two
      #           alphabets only)
      # tweak:    defaults to "table.column"
      def has_code(column, sequence:, format:, prefix: "", cipher: :ff1, tweak: nil)
        column = column.to_sym
        opts = { sequence: sequence, format: format, prefix: prefix.to_s, cipher: cipher, tweak: tweak }
        GFC64::Model.check_options!(opts, :has_code)
        gfc64_codes[column] = opts
        include CodeMethods
        before_create { assign_code(column) if self[column].nil? || self[column].to_s.empty? } if respond_to?(:before_create)
      end

      def gfc64_codes
        @gfc64_codes ||= {}
      end

      # ---- public ids ------------------------------------------------------

      def encode_public_id(id)
        o = public_id_options
        n = public_id_cipher.encrypt(id)
        o[:format] ? o[:format].encode(n) : n.to_s
      end

      # The record id for a public id String, or nil when it isn't one.
      def decode_public_id(value)
        o = public_id_options
        s = value.to_s.strip
        n = o[:format] ? o[:format].decode(s) : Integer(s, 10)
        public_id_cipher.decrypt(n)
      rescue ArgumentError, TypeError
        nil
      end

      def find_by_public_id(value)
        id = decode_public_id(value)
        id && find_by(primary_key => id)
      end

      def find_by_public_id!(value)
        find_by_public_id(value) || raise(GFC64::Model.not_found_error, "Couldn't find #{name} with public id #{value.to_s[0, 64].inspect}")
      end

      def public_id_cipher
        gfc64_cached(:public_id) { GFC64::Model.build_cipher(public_id_options, default_tweak: table_name.to_s) }
      end

      # ---- stored codes ----------------------------------------------------

      # The stored form of a code, however it was typed; nil when it isn't one.
      def normalize_code(column, value)
        o = code_options(column)
        s = value.to_s.strip
        candidates = [s]
        core = o[:prefix].gsub(/[\s\-_]/, "")
        # The prefix is optional and may be typed in any case or spacing
        # ("app tcnh r99b"); try without it first, then the text as given in
        # case the code itself starts with the same letters.
        candidates.unshift(s.sub(/\A#{Regexp.escape(core)}[\s\-_]*/i, "")) if !core.empty? && s =~ /\A#{Regexp.escape(core)}/i
        candidates.each do |c|
          begin
            return o[:prefix] + o[:format].encode(o[:format].decode(c))
          rescue ArgumentError
            next
          end
        end
        nil
      rescue ArgumentError, TypeError
        nil
      end

      def find_by_code(column, value)
        code = normalize_code(column, value)
        code && find_by(column.to_sym => code)
      end

      def find_by_code!(column, value)
        find_by_code(column, value) || raise(GFC64::Model.not_found_error, "Couldn't find #{name} with #{column} #{value.to_s[0, 64].inspect}")
      end

      # The sequence value a code was made from (for bookkeeping), or nil.
      def code_sequence_value(column, code)
        o = code_options(column)
        stored = normalize_code(column, code) or return nil
        code_cipher(column).decrypt(o[:format].decode(stored[o[:prefix].length..-1]))
      end

      def generate_code(column)
        o = code_options(column)
        value = o[:sequence].respond_to?(:call) ? o[:sequence].call : next_sequence_value(o[:sequence])
        value = Integer(value)
        o[:prefix] + o[:format].encode(code_cipher(column).encrypt(value))
      end

      def code_cipher(column)
        gfc64_cached(:"code_#{column}") do
          GFC64::Model.build_cipher(code_options(column), default_tweak: "#{table_name}.#{column}")
        end
      end

      private

      def public_id_options
        klass = self
        while klass.respond_to?(:public_id_cipher)
          o = klass.instance_variable_get(:@gfc64_public_id)
          return o if o

          klass = klass.superclass
        end
        raise ArgumentError, "#{name} has no has_public_id"
      end

      def code_options(column)
        klass = self
        while klass.respond_to?(:gfc64_codes)
          o = klass.gfc64_codes[column.to_sym]
          return o if o

          klass = klass.superclass
        end
        raise ArgumentError, "#{name} has no has_code #{column.inspect}"
      end

      def next_sequence_value(name)
        conn = connection
        conn.select_value("SELECT nextval(#{conn.quote(name.to_s)})")
      end

      def gfc64_cached(slot)
        gen = GFC64.cipher_generation
        @gfc64_ciphers = {} if @gfc64_cipher_gen != gen
        @gfc64_cipher_gen = gen
        @gfc64_ciphers[slot] ||= yield
      end
    end

    module PublicIdMethods
      def public_id
        id = self[self.class.primary_key]
        id && self.class.encode_public_id(id)
      end
    end

    module CodeMethods
      def assign_code(column)
        self[column] = self.class.generate_code(column)
      end

      def code_sequence_value(column)
        self.class.code_sequence_value(column, self[column])
      end
    end

    # ---- shared ---------------------------------------------------------------

    def self.check_options!(o, macro)
      unless %i[feistel ff1].include?(o[:cipher])
        raise ArgumentError, "#{macro}: cipher must be :feistel or :ff1"
      end
      fmt = o[:format]
      if macro == :has_code
        raise ArgumentError, "has_code: format: is required (e.g. GFC64::Format::Crockford32.new(length: 8))" unless fmt.is_a?(GFC64::Format::Alphabet)
        unless o[:sequence].respond_to?(:call) || o[:sequence].is_a?(String) || o[:sequence].is_a?(Symbol)
          raise ArgumentError, "has_code: sequence: must be a sequence name or a callable"
        end
      end
      if fmt && !fmt.is_a?(GFC64::Format::Alphabet)
        raise ArgumentError, "#{macro}: format must be a GFC64::Format"
      end
      if o[:cipher] == :ff1 && fmt.nil?
        raise ArgumentError, "#{macro}: cipher: :ff1 needs a format: (its radix and length set the domain)"
      end
      if o[:cipher] == :feistel && fmt
        bits = o[:bits] || fmt.bits
        if (2**bits - 1) > fmt.max
          raise ArgumentError, "#{macro}: #{bits}-bit values don't fit #{fmt.length} characters of this format"
        end
      end
      o[:tweak] = o[:tweak].to_s unless o[:tweak].nil? || o[:tweak] == false
    end

    def self.build_cipher(o, default_tweak:)
      key = GFC64.config.key
      # false: no tweak at all (the 0.1.0 mixin's numbers).
      tweak = o[:tweak] == false ? nil : (o[:tweak] || default_tweak)
      test_key = GFC64.config.insecure_test_key ? true : false
      if o[:cipher] == :ff1
        fmt = o[:format]
        GFC64::FF1.new([key].pack("H*"), radix: fmt.radix, length: fmt.length, tweak: tweak || "", insecure_test_key: test_key)
      else
        bits = o[:bits] || feistel_bits(o[:format])
        GFC64.new(key, bits: bits, tweak: tweak, insecure_test_key: test_key)
      end
    end

    # For has_code with cipher: :feistel: the format's width, which must be a
    # power-of-two alphabet filled exactly (e.g. Crockford32 length 8 = 40 bits).
    def self.feistel_bits(fmt)
      bits = fmt.bits
      unless fmt.max == 2**bits - 1 && bits.even? && bits.between?(GFC64::MIN_BITS, GFC64::MAX_BITS)
        raise ArgumentError, "cipher: :feistel needs a power-of-two alphabet filling an even 16-64 bits; use cipher: :ff1"
      end

      bits
    end
  end
end

if defined?(ActiveSupport) && ActiveSupport.respond_to?(:on_load)
  ActiveSupport.on_load(:active_record) { include GFC64::Model }
end
