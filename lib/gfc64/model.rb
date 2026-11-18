# frozen_string_literal: true

class GFC64
  # Raised by a guarded find (has_public_id guard_find: true) given a String
  # that isn't an id. An ArgumentError, so it's a loud error, not a 404.
  class UnsafeFind < ArgumentError; end

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
  #     has_code :number, prefix: "APP-", # made from the id, stored in "number"
  #                       format: GFC64::Format::Crockford32.new(length: 8, group: 4)
  #   end
  #   Invoice.create!.number                          # => "APP-TCNH-R99B"
  #   Invoice.find_by_code!(:number, "app tcnh-r99b") # any case, spacing, O/I/L
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
      # prefix: added in front, e.g. "INV-"; optional, any case, when decoding
      # param:  false keeps to_param as the plain id
      # guard_find: true makes find raise GFC64::UnsafeFind when given a
      #         String that isn't all digits, instead of ActiveRecord reading
      #         its leading digits ("7KQM-R3XH" as 7) and returning another
      #         record. Covers Model.find, relations and associations.
      def has_public_id(bits: 64, format: nil, cipher: :feistel, tweak: nil, prefix: "", param: true, guard_find: false)
        opts = { bits: bits, format: format, cipher: cipher, tweak: tweak, prefix: prefix.to_s }
        GFC64::Model.check_options!(opts, :has_public_id)
        @gfc64_public_id = opts
        include PublicIdMethods
        define_method(:to_param) { public_id } if param
        GFC64::Model.guard_find!(self) if guard_find
      end

      # A code stored in `column`, made on create from the record's own
      # primary key (by default) or a separate counter: encrypted (FF1 by
      # default), formatted, prefixed.
      #
      # sequence: :primary_key (default) reuses the auto-incremented id. On
      #           Postgres the id is taken from the table's own sequence
      #           before the INSERT, so the code goes in the same write and
      #           the column can be NOT NULL; elsewhere the code is filled in
      #           right after the INSERT (same transaction; the column must
      #           allow NULL). Or a sequence name / callable for numbering
      #           that's independent of the id.
      # format:   a GFC64::Format (required)
      # prefix:   added in front, e.g. "APP-"; optional when looking up
      # cipher:   :ff1 (default; any alphabet) or :feistel (power-of-two
      #           alphabets only)
      # tweak:    defaults to "table.column"
      def has_code(column, format:, sequence: :primary_key, prefix: "", cipher: :ff1, tweak: nil)
        column = column.to_sym
        opts = { sequence: sequence, format: format, prefix: prefix.to_s, cipher: cipher, tweak: tweak }
        GFC64::Model.check_options!(opts, :has_code)
        gfc64_codes[column] = opts
        include CodeMethods
        return unless respond_to?(:before_create)

        before_create { gfc64_before_create_code(column) }
        after_create { gfc64_after_create_code(column) }
      end

      def gfc64_codes
        @gfc64_codes ||= {}
      end

      # ---- public ids ------------------------------------------------------

      def encode_public_id(id)
        o = public_id_options
        n = public_id_cipher.encrypt(id)
        o[:prefix] + (o[:format] ? o[:format].encode(n) : n.to_s)
      end

      # The record id for a public id String (prefix optional; any case and
      # spacing the format allows), or nil when it isn't one.
      #
      # strict: true accepts only the exact canonical form (what to_param
      # returns), e.g. for input from machines.
      def decode_public_id(value, strict: false)
        if strict
          id = decode_public_id(value)
          return id && encode_public_id(id) == value ? id : nil
        end

        o = public_id_options
        GFC64::Model.prefix_candidates(value, o[:prefix]).each do |s|
          begin
            n = o[:format] ? o[:format].decode(s) : Integer(s, 10)
            return public_id_cipher.decrypt(n)
          rescue ArgumentError, TypeError
            next
          end
        end
        nil
      end

      def find_by_public_id(value, strict: false)
        id = decode_public_id(value, strict: strict)
        id && find_by(primary_key => id)
      end

      def find_by_public_id!(value, strict: false)
        find_by_public_id(value, strict: strict) || raise(GFC64::Model.not_found_error, "Couldn't find #{name} with public id #{value.to_s[0, 64].inspect}")
      end

      # The canonical form of a public id however it was typed (for a redirect
      # to the canonical URL), or nil when it isn't one.
      def canonical_public_id(value)
        id = decode_public_id(value)
        id && encode_public_id(id)
      end

      def public_id_cipher
        gfc64_cached(:public_id) { GFC64::Model.build_cipher(public_id_options, default_tweak: table_name.to_s) }
      end

      # ---- stored codes ----------------------------------------------------

      # The stored form of a code, however it was typed; nil when it isn't one.
      def normalize_code(column, value)
        o = code_options(column)
        GFC64::Model.prefix_candidates(value, o[:prefix]).each do |c|
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

      # strict: true accepts only the stored canonical form.
      def find_by_code(column, value, strict: false)
        code = normalize_code(column, value)
        return nil if code.nil? || (strict && code != value)

        find_by(column.to_sym => code)
      end

      def find_by_code!(column, value, strict: false)
        find_by_code(column, value, strict: strict) || raise(GFC64::Model.not_found_error, "Couldn't find #{name} with #{column} #{value.to_s[0, 64].inspect}")
      end

      # The sequence value a code was made from (for bookkeeping), or nil.
      def code_sequence_value(column, code)
        o = code_options(column)
        stored = normalize_code(column, code) or return nil
        code_cipher(column).decrypt(o[:format].decode(stored[o[:prefix].length..-1]))
      end

      # The code for a counter value; with no value, the next one from the
      # configured sequence (not for sequence: :primary_key, which uses the
      # record's id).
      def generate_code(column, value = nil)
        o = code_options(column)
        if value.nil?
          raise ArgumentError, "#{column} uses the primary key; pass the id" if o[:sequence] == :primary_key

          value = o[:sequence].respond_to?(:call) ? o[:sequence].call : next_sequence_value(o[:sequence])
        end
        o[:prefix] + o[:format].encode(code_cipher(column).encrypt(Integer(value)))
      end

      # The next id from the table's own sequence (Postgres), or nil where
      # that isn't available.
      def gfc64_prefetch_primary_key
        seq = gfc64_primary_key_sequence
        seq && connection.select_value("SELECT nextval(#{connection.quote(seq)})")
      end

      # The table's id sequence, looked up once per model (it doesn't change);
      # nil off Postgres or when the id has no sequence.
      def gfc64_primary_key_sequence
        return @gfc64_pk_sequence if defined?(@gfc64_pk_sequence)

        conn = connection
        @gfc64_pk_sequence =
          if conn.adapter_name.to_s =~ /postg/i
            conn.select_value("SELECT pg_get_serial_sequence(#{conn.quote(table_name.to_s)}, #{conn.quote(primary_key.to_s)})")
          end
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

      private

      def gfc64_blank?(column)
        self[column].nil? || self[column].to_s.empty?
      end

      def gfc64_before_create_code(column)
        return unless gfc64_blank?(column)

        if self.class.send(:code_options, column)[:sequence] != :primary_key
          assign_code(column)
          return
        end

        pk = self.class.primary_key
        self[pk] ||= self.class.gfc64_prefetch_primary_key
        self[column] = self.class.generate_code(column, self[pk]) if self[pk]
      end

      # Databases without a sequence to read ahead: the id exists now.
      def gfc64_after_create_code(column)
        return unless gfc64_blank?(column)

        update_columns(column => self.class.generate_code(column, self[self.class.primary_key]))
      end
    end

    # ---- guarded find ---------------------------------------------------------

    # Prepended to the model's class and its relation classes.
    module FindGuard
      def find(*args, &block)
        GFC64::Model.check_find_args!(self, args) unless block # with a block it's Enumerable#find
        super
      end
    end

    def self.guard_find!(model)
      model.singleton_class.prepend(FindGuard)
      return unless defined?(::ActiveRecord::Relation) && model.respond_to?(:relation_delegate_class)

      relation_classes = [::ActiveRecord::Relation]
      relation_classes << ::ActiveRecord::AssociationRelation if defined?(::ActiveRecord::AssociationRelation)
      relation_classes << ::ActiveRecord::Associations::CollectionProxy if defined?(::ActiveRecord::Associations::CollectionProxy)
      relation_classes.each { |k| model.relation_delegate_class(k).prepend(FindGuard) }
    end

    def self.check_find_args!(scope, args)
      args.flatten.each do |a|
        next unless a.is_a?(String)
        next if a.match?(/\A\d+\z/)

        model = scope.respond_to?(:model) ? scope.model : scope
        raise UnsafeFind, "#{model.name}.find was given #{a[0, 64].inspect}, which isn't an id: ActiveRecord would read " \
                          "its leading digits and could return another record. For a public id use " \
                          "#{model.name}.find_by_public_id!(...)."
      end
    end

    # ---- shared ---------------------------------------------------------------

    # What to try decoding. The prefix is optional and matched in any case;
    # only the prefix itself is removed, so the format alone decides which
    # remaining characters (spaces, separators, look-alikes) it can safely
    # ignore. Tried in order: without the full prefix ("INV-"), without its
    # letters alone ("inv tcnh"), then as given (a code may start with the
    # prefix's letters). Codes have a fixed length, so at most one fits.
    def self.prefix_candidates(value, prefix)
      s = value.to_s.strip
      p = prefix.to_s
      return [s] if p.empty?

      out = []
      out << s[p.length..-1] if s.length >= p.length && s[0, p.length].casecmp(p).zero?
      core = p.gsub(/[^[:alnum:]]/, "")
      out << s[core.length..-1] if !core.empty? && core != p && s.length >= core.length && s[0, core.length].casecmp(core).zero?
      out << s
      out.uniq
    end

    def self.check_options!(o, macro)
      unless %i[feistel ff1].include?(o[:cipher])
        raise ArgumentError, "#{macro}: cipher must be :feistel or :ff1"
      end
      fmt = o[:format]
      if macro == :has_code
        raise ArgumentError, "has_code: format: is required (e.g. GFC64::Format::Crockford32.new(length: 8))" unless fmt.is_a?(GFC64::Format::Alphabet)
        unless o[:sequence].respond_to?(:call) || o[:sequence].is_a?(String) || o[:sequence].is_a?(Symbol)
          raise ArgumentError, "has_code: sequence: must be :primary_key, a sequence name or a callable"
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
