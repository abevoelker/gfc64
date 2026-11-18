begin
  require "active_record"
  require "sqlite3"
rescue LoadError
  # Older Rubies: the Gemfile skips ActiveRecord, and so do these specs.
end

if defined?(ActiveRecord::Base)
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  ActiveRecord::Migration.verbose = false
  ActiveRecord::Schema.define do
    create_table(:customers) { |t| t.string :name }
    create_table(:orders) { |t| t.string :name }
    create_table(:invoices) do |t|
      t.string :number
      t.string :name
      t.integer :customer_id
      t.index :number, unique: true
    end
  end

  class GFC64ModelSpecRecord < ActiveRecord::Base
    self.abstract_class = true
    include GFC64::Model
  end

  # A stand-in for a database sequence (SQLite has none).
  module SpecSequence
    def self.next
      @n = (@n || 0) + 1
    end

    def self.reset!
      @n = 0
    end
  end

  RSpec.describe GFC64::Model do
    before(:all) { @saved_key = ENV["GFC64_KEY"] }
    after(:all) { ENV["GFC64_KEY"] = @saved_key }

    before do
      GFC64.configure { |c| c.key = GFC64.generate_key }
      SpecSequence.reset!
      stub_const("Customer", Class.new(GFC64ModelSpecRecord) {
        self.table_name = "customers"
        define_singleton_method(:name) { "Customer" }
        has_public_id bits: 40, format: GFC64::Format::Base58.new(bits: 40)
      })
      stub_const("Order", Class.new(GFC64ModelSpecRecord) {
        self.table_name = "orders"
        define_singleton_method(:name) { "Order" }
        has_public_id bits: 40, format: GFC64::Format::Base58.new(bits: 40)
      })
      stub_const("Invoice", Class.new(GFC64ModelSpecRecord) {
        self.table_name = "invoices"
        define_singleton_method(:name) { "Invoice" }
        has_code :number, sequence: -> { SpecSequence.next }, prefix: "APP-",
                          format: GFC64::Format::Crockford32.new(length: 8, group: 4)
      })
    end

    describe "has_public_id" do
      it "puts an encrypted, formatted id in to_param and finds the record from it" do
        c = Customer.create!(name: "a")
        expect(c.to_param).to eq(c.public_id)
        expect(c.public_id).to match(/\A[1-9A-HJ-NP-Za-km-z]{7}\z/)
        expect(c.public_id).not_to eq(c.id.to_s)
        expect(Customer.find_by_public_id!(c.to_param)).to eq(c)
        expect(Customer.decode_public_id(c.public_id)).to eq(c.id)
      end

      it "answers bad, unknown and out-of-range ids with nil / RecordNotFound, never ArgumentError" do
        Customer.create!(name: "a")
        ["", "!!!", "0OIl000", "zzzzzzz", "1234567890", nil, Customer.encode_public_id(999_999)].each do |bad|
          expect(Customer.find_by_public_id(bad)).to be_nil
          expect { Customer.find_by_public_id!(bad) }.to raise_error(ActiveRecord::RecordNotFound)
        end
      end

      it "gives each model its own mapping (tweak = table name)" do
        expect(Customer.encode_public_id(5)).not_to eq(Order.encode_public_id(5))
        expect(Order.decode_public_id(Customer.encode_public_id(5))).not_to eq(5)
      end

      it "is nil for unsaved records" do
        expect(Customer.new.public_id).to be_nil
      end

      it "works without a format (a plain encrypted number) and with param: false" do
        klass = Class.new(GFC64ModelSpecRecord) { self.table_name = "customers"; has_public_id param: false }
        c = klass.create!(name: "b")
        expect(c.to_param).to eq(c.id.to_s)
        expect(c.public_id).to match(/\A\d+\z/)
        expect(klass.find_by_public_id(c.public_id)).to eq(c)
      end

      it "computes prefixed, invoice-style codes from the primary key, storing nothing" do
        klass = Class.new(GFC64ModelSpecRecord) {
          self.table_name = "invoices"
          has_public_id cipher: :ff1, prefix: "INV-", format: GFC64::Format::Crockford32.new(length: 8, group: 4)
        }
        i = klass.create!(name: "p")
        expect(i.public_id).to match(/\AINV-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}\z/)
        expect(i.to_param).to eq(i.public_id)
        expect(i.reload.number).to be_nil # nothing written
        typed = i.public_id.sub("INV-", "inv ").downcase.tr("-", " ").tr("0", "o").tr("1", "l")
        [i.public_id, typed, i.public_id.sub("INV-", "")].each do |v|
          expect(klass.find_by_public_id!(v)).to eq(i)
        end
        ["INV-", "INV-UUUU-UUUU", "INV-1234-567", "nope", nil].each do |bad|
          expect(klass.find_by_public_id(bad)).to be_nil
        end
      end

      it "leaves separator-like characters to the format (an alphabet that uses - and _ as digits)" do
        b64url = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        fmt = GFC64::Format::Alphabet.new(b64url, length: 4, ignore: "")
        klass = Class.new(GFC64ModelSpecRecord) {
          self.table_name = "customers"
          has_public_id cipher: :ff1, prefix: "c-", format: fmt
        }
        # Find ids whose codes start with "-" or "_" and check they come back.
        records = Array.new(400) { |n| klass.create!(name: n.to_s) }
        edgy = records.select { |r| r.public_id.sub("c-", "") =~ /\A[-_]/ }
        expect(edgy).not_to be_empty
        edgy.each do |r|
          expect(klass.find_by_public_id(r.public_id)).to eq(r)
          expect(klass.find_by_public_id(r.public_id.sub("c-", "C-"))).to eq(r)
        end
        # Case-sensitive format: a swapped-case code is a different code.
        lettered = records.find { |r| r.public_id.sub("c-", "") =~ /[a-zA-Z]/ }
        expect(klass.find_by_public_id("c-" + lettered.public_id.sub("c-", "").swapcase)).not_to eq(lettered)
      end

      it "finds strictly on request, and gives the canonical form for redirects" do
        klass = Class.new(GFC64ModelSpecRecord) {
          self.table_name = "invoices"
          has_public_id cipher: :ff1, prefix: "INV-", format: GFC64::Format::Crockford32.new(length: 8, group: 4)
        }
        i = klass.create!(name: "s")
        typed = i.public_id.downcase
        expect(klass.find_by_public_id(typed)).to eq(i)
        expect(klass.find_by_public_id(typed, strict: true)).to be_nil
        expect { klass.find_by_public_id!(typed, strict: true) }.to raise_error(ActiveRecord::RecordNotFound)
        expect(klass.find_by_public_id!(i.public_id, strict: true)).to eq(i)
        expect(klass.canonical_public_id(typed)).to eq(i.to_param)
        expect(klass.canonical_public_id("junk")).to be_nil
        expect(klass.decode_public_id(i.public_id.sub("INV-", "inv-"), strict: true)).to be_nil
      end

      it "puts a prefix on plain numbers too" do
        klass = Class.new(GFC64ModelSpecRecord) { self.table_name = "customers"; has_public_id prefix: "c_" }
        c = klass.create!(name: "n")
        expect(c.public_id).to match(/\Ac_\d+\z/)
        expect(klass.find_by_public_id(c.public_id)).to eq(c)
        expect(klass.find_by_public_id(c.public_id.sub("c_", ""))).to eq(c)
      end

      it "can use FF1 with a length-based format" do
        klass = Class.new(GFC64ModelSpecRecord) {
          self.table_name = "customers"
          has_public_id cipher: :ff1, format: GFC64::Format::Crockford32.new(length: 8)
        }
        c = klass.create!(name: "c")
        expect(c.public_id).to match(/\A[0-9A-Z]{8}\z/)
        expect(klass.find_by_public_id!(c.public_id.downcase)).to eq(c)
      end
    end

    describe "has_code" do
      it "stores a prefixed code from the sequence on create" do
        a = Invoice.create!(name: "a")
        b = Invoice.create!(name: "b")
        expect(a.number).to match(/\AAPP-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}\z/)
        expect(a.reload.number).not_to eq(b.number)
        expect(a.code_sequence_value(:number)).to eq(1)
        expect(b.code_sequence_value(:number)).to eq(2)
      end

      it "reuses the primary key by default (no sequence: needed)" do
        klass = Class.new(GFC64ModelSpecRecord) {
          self.table_name = "invoices"
          has_code :number, prefix: "APP-", format: GFC64::Format::Crockford32.new(length: 8, group: 4)
        }
        a = klass.create!(name: "pk1")
        b = klass.create!(name: "pk2")
        expect(a.number).to match(/\AAPP-[0-9A-Z]{4}-[0-9A-Z]{4}\z/)
        expect(a.reload.number).not_to be_nil # filled in after the INSERT on SQLite
        expect(a.code_sequence_value(:number)).to eq(a.id)
        expect(b.code_sequence_value(:number)).to eq(b.id)
        expect(klass.find_by_code!(:number, a.number.downcase)).to eq(a)
      end

      it "uses an explicitly set id for the code" do
        klass = Class.new(GFC64ModelSpecRecord) {
          self.table_name = "invoices"
          has_code :number, format: GFC64::Format::Crockford32.new(length: 8)
        }
        i = klass.create!(id: 900_001, name: "explicit")
        expect(i.code_sequence_value(:number)).to eq(900_001)
      end

      it "keeps a code that was set explicitly" do
        i = Invoice.create!(name: "x", number: "APP-0000-0001")
        expect(i.number).to eq("APP-0000-0001")
        expect(SpecSequence.next).to eq(1) # the sequence wasn't used
      end

      it "finds a code however it's typed: any case, spacing, O/I/L, with or without the prefix" do
        i = Invoice.create!(name: "a")
        typed = i.number.sub("APP-", "app ").downcase.tr("-", " ").tr("0", "o").tr("1", "l")
        expect(Invoice.find_by_code!(:number, typed)).to eq(i)
        expect(Invoice.find_by_code!(:number, i.number.sub("APP-", ""))).to eq(i)
        expect(Invoice.normalize_code(:number, typed)).to eq(i.number)
      end

      it "finds codes strictly on request" do
        i = Invoice.create!(name: "a")
        expect(Invoice.find_by_code(:number, i.number, strict: true)).to eq(i)
        expect(Invoice.find_by_code(:number, i.number.downcase, strict: true)).to be_nil
        expect { Invoice.find_by_code!(:number, i.number.delete("-"), strict: true) }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "answers malformed and unknown codes with nil / RecordNotFound" do
        Invoice.create!(name: "a")
        ["", "APP-", "APP-UUUU-UUUU", "APP-1234-567", "nope", nil, "APP-0000-0000"].each do |bad|
          expect(Invoice.find_by_code(:number, bad)).to be_nil
          expect { Invoice.find_by_code!(:number, bad) }.to raise_error(ActiveRecord::RecordNotFound)
        end
      end

      it "never repeats over many creates" do
        numbers = Array.new(300) { |n| Invoice.create!(name: n.to_s).number }
        expect(numbers.uniq.size).to eq(300)
      end

      it "can use the Feistel cipher with a power-of-two alphabet" do
        klass = Class.new(GFC64ModelSpecRecord) {
          self.table_name = "invoices"
          has_code :number, sequence: -> { SpecSequence.next + 10_000 }, cipher: :feistel,
                            format: GFC64::Format::Crockford32.new(length: 8)
        }
        i = klass.create!(name: "f")
        expect(i.number).to match(/\A[0-9A-Z]{8}\z/)
        expect(i.code_sequence_value(:number)).to be > 10_000
      end

      it "rejects bad options when the class is defined" do
        expect { Class.new(GFC64ModelSpecRecord) { has_code :number, sequence: "s", format: nil } }
          .to raise_error(ArgumentError, /format/)
        expect { Class.new(GFC64ModelSpecRecord) { has_code :number, sequence: 5, format: GFC64::Format::Decimal.new(length: 8) } }
          .to raise_error(ArgumentError, /sequence/)
        expect { Class.new(GFC64ModelSpecRecord) { has_code :number, sequence: "s", cipher: :rot13, format: GFC64::Format::Decimal.new(length: 8) } }
          .to raise_error(ArgumentError, /cipher/)
      end
    end

    describe "guard_find" do
      before do
        stub_const("GuardCustomer", Class.new(GFC64ModelSpecRecord) {
          self.table_name = "customers"
          has_many :guard_invoices, class_name: "GuardInvoice", foreign_key: :customer_id
        })
        stub_const("GuardInvoice", Class.new(GFC64ModelSpecRecord) {
          self.table_name = "invoices"
          has_public_id cipher: :ff1, format: GFC64::Format::Crockford32.new(length: 8, group: 4), guard_find: true
        })
        @customer = GuardCustomer.create!(name: "c")
        @invoices = Array.new(8) { |n| GuardInvoice.create!(name: n.to_s, customer_id: @customer.id) }
      end

      it "shows the problem it guards against: without it, find reads a code's leading digits" do
        unguarded = Class.new(GFC64ModelSpecRecord) { self.table_name = "invoices" }
        id = @invoices.first.id
        expect(unguarded.find("#{id}KQM-R3XH").id).to eq(id)
      end

      it "raises UnsafeFind for Strings that aren't ids, with a pointer to find_by_public_id!" do
        ["7KQM-R3XH", "3abc", "BQZbwjf", "7 ", "", "-1"].each do |v|
          expect { GuardInvoice.find(v) }.to raise_error(GFC64::UnsafeFind, /find_by_public_id!/)
        end
        expect { GuardInvoice.find([1, "2x"]) }.to raise_error(GFC64::UnsafeFind)
        expect(GFC64::UnsafeFind.ancestors).to include(ArgumentError)
      end

      it "still accepts real ids: Integers, digit Strings, arrays of them" do
        a, b = @invoices[0].id, @invoices[1].id
        expect(GuardInvoice.find(a).id).to eq(a)
        expect(GuardInvoice.find(a.to_s).id).to eq(a)
        expect(GuardInvoice.find([a, b.to_s]).map(&:id)).to eq([a, b])
        expect { GuardInvoice.find(2**40) }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "covers relations and associations too" do
        expect { GuardInvoice.where(name: "1").find("7KQM") }.to raise_error(GFC64::UnsafeFind)
        expect { @customer.guard_invoices.find("7KQM") }.to raise_error(GFC64::UnsafeFind)
        expect { @customer.guard_invoices.where(name: "1").find("7KQM") }.to raise_error(GFC64::UnsafeFind)
        expect(@customer.guard_invoices.find(@invoices[2].id)).to eq(@invoices[2])
      end

      it "leaves Enumerable#find (with a block) and find_by_public_id alone" do
        expect(GuardInvoice.where(customer_id: @customer.id).find { |i| i.name == "3" }).to eq(@invoices[3])
        expect(GuardInvoice.find_by_public_id!(@invoices[4].public_id)).to eq(@invoices[4])
      end

      it "is off unless asked for" do
        expect(Invoice.find(Invoice.create!(name: "x").id.to_s + "abc")).to be_a(Invoice)
      end
    end

    describe "the key" do
      it "is read on first use, from GFC64_KEY when not configured" do
        GFC64.configure { |c| c.key = nil }
        ENV["GFC64_KEY"] = nil
        expect { Invoice.create!(name: "a") }.to raise_error(GFC64::KeyMissing, /GFC64_KEY/)
        ENV["GFC64_KEY"] = GFC64.generate_key
        GFC64.reset_ciphers!
        expect(Invoice.create!(name: "b").number).to start_with("APP-")
      end

      it "must be 64 hex characters" do
        GFC64.configure { |c| c.key = "too short" }
        expect { Customer.encode_public_id(1) }.to raise_error(ArgumentError, /64 hex/)
      end

      it "can be a callable (read when first needed)" do
        k = GFC64.generate_key
        GFC64.configure { |c| c.key = -> { k } }
        expect(Customer.decode_public_id(Customer.encode_public_id(9))).to eq(9)
      end

      it "changes every value when it changes" do
        before_change = Customer.encode_public_id(9)
        GFC64.configure { |c| c.key = GFC64.generate_key }
        expect(Customer.encode_public_id(9)).not_to eq(before_change)
      end
    end

    describe "the 0.1.0 mixin (deprecated)" do
      it "has_public_id tweak: false gives the same numbers as the old mixin" do
        key = GFC64.generate_key
        GFC64.configure { |c| c.key = key }
        klass = Class.new(GFC64ModelSpecRecord) { self.table_name = "customers"; has_public_id tweak: false }
        c = klass.create!(name: "same")
        expect(c.to_param).to eq(GFC64.new(key).encrypt(c.id).to_s)
      end

      it "finds from a String param and turns bad ones into RecordNotFound" do
        gfc = GFC64.new(GFC64.generate_key)
        klass = Class.new(ActiveRecord::Base) { self.table_name = "customers"; include GFC64::ActiveRecord[gfc] }
        c = klass.create!(name: "old")
        expect(klass.find_gfc(c.to_param)).to eq(c)
        ["abc", "", (2**64).to_s].each do |bad|
          expect { klass.find_gfc(bad) }.to raise_error(ActiveRecord::RecordNotFound)
        end
      end
    end

    if ENV["GFC64_PG_URL"]
      describe "with Postgres, reusing the primary key" do
        it "reads the next id ahead, so the code goes in the same INSERT (NOT NULL column)" do
          require "pg"
          pg = stub_const("GFC64PgPkSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true; include GFC64::Model })
          pg.establish_connection(ENV["GFC64_PG_URL"])
          pg.connection.execute("CREATE TEMPORARY TABLE gfc64_spec_pk_invoices (id bigserial primary key, number text NOT NULL UNIQUE)")
          klass = Class.new(pg) {
            self.table_name = "gfc64_spec_pk_invoices"
            has_code :number, prefix: "APP-", format: GFC64::Format::Crockford32.new(length: 8, group: 4)
          }
          a = klass.create!
          b = klass.create!
          expect([a.code_sequence_value(:number), b.code_sequence_value(:number)]).to eq([a.id, b.id])
          expect(b.id).to eq(a.id + 1)
          expect(klass.find_by_code!(:number, b.number)).to eq(b)
        end

        it "advances the id sequence once per record, with one nextval and the id in the INSERT" do
          pg = stub_const("GFC64PgOnceSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true; include GFC64::Model })
          pg.establish_connection(ENV["GFC64_PG_URL"])
          pg.connection.execute("CREATE TEMPORARY TABLE gfc64_spec_once (id bigserial primary key, number text NOT NULL UNIQUE)")
          klass = Class.new(pg) { self.table_name = "gfc64_spec_once"; has_code :number, format: GFC64::Format::Crockford32.new(length: 8) }
          klass.create! # warm up: looks up the sequence name once
          sql = []
          sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| sql << p[:sql] }
          begin
            4.times { klass.create! }
          ensure
            ActiveSupport::Notifications.unsubscribe(sub)
          end
          ids = klass.order(:id).pluck(:id)
          expect(ids).to eq((ids.first..ids.first + 4).to_a)
          seq = klass.gfc64_primary_key_sequence
          expect(pg.connection.select_value("SELECT last_value FROM #{seq}").to_i).to eq(ids.last)
          expect(sql.count { |q| q.include?("nextval") }).to eq(4)
          expect(sql.count { |q| q.include?("pg_get_serial_sequence") }).to eq(0) # cached
          expect(sql.grep(/INSERT/).all? { |q| q.include?('"id"') }).to be true
        end

        it "never hands two concurrent creates the same id or code" do
          url = ENV["GFC64_PG_URL"]
          pg = stub_const("GFC64PgRaceSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true; include GFC64::Model })
          pg.establish_connection(url + (url.include?("?") ? "&" : "?") + "pool=10")
          table = "gfc64_spec_race_#{Process.pid}"
          pg.connection.execute("CREATE TABLE #{table} (id bigserial primary key, number text NOT NULL UNIQUE)")
          begin
            klass = Class.new(pg) { self.table_name = table; has_code :number, format: GFC64::Format::Crockford32.new(length: 8) }
            go = Queue.new
            threads = Array.new(8) do
              Thread.new do
                go.pop
                pg.connection_pool.with_connection { Array.new(25) { klass.create! }.map { |r| [r.id, r.number] } }
              end
            end
            8.times { go << true }
            rows = threads.flat_map(&:value)
            expect(rows.map(&:first).uniq.size).to eq(200)
            expect(rows.map(&:last).uniq.size).to eq(200)
            expect(rows.all? { |id, n| klass.code_sequence_value(:number, n) == id }).to be true
          ensure
            pg.connection.execute("DROP TABLE IF EXISTS #{table}")
          end
        end
      end

      describe "with a real Postgres sequence" do
        it "takes values from nextval" do
          require "pg"
          pg = stub_const("GFC64PgSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true; include GFC64::Model })
          pg.establish_connection(ENV["GFC64_PG_URL"])
          pg.connection.execute("CREATE TEMPORARY TABLE gfc64_spec_invoices (id bigserial primary key, number text)")
          pg.connection.execute("CREATE TEMPORARY SEQUENCE gfc64_spec_numbers")
          klass = Class.new(pg) {
            self.table_name = "gfc64_spec_invoices"
            has_code :number, sequence: "gfc64_spec_numbers", format: GFC64::Format::Crockford32.new(length: 8)
          }
          a = klass.create!
          b = klass.create!
          expect([a.code_sequence_value(:number), b.code_sequence_value(:number)]).to eq([1, 2])
        end
      end
    end
  end
end
