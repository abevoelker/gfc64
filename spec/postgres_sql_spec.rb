# The Postgres implementation (sql/gfc64_postgres.sql) must match the gem
# exactly. Runs only with GFC64_PG_URL; everything happens in one transaction
# that's rolled back, so the database is left as it was.
if ENV["GFC64_PG_URL"]
  begin
    require "active_record"
    require "pg"
  rescue LoadError
    nil
  end
end

if ENV["GFC64_PG_URL"] && defined?(PG)
  RSpec.describe "sql/gfc64_postgres.sql" do
    SQL_FILE = File.expand_path("../sql/gfc64_postgres.sql", __dir__)
    K128 = "2B7E151628AED2A6ABF7158809CF4F3C".freeze unless defined?(K128)
    K192 = (K128 + "EF4359D8D580AA4F").freeze unless defined?(K192)
    K256 = (K192 + "7F036D6F04FC6A94").freeze unless defined?(K256)
    T2 = "39383736353433323130".freeze unless defined?(T2)
    T3 = "3737373770717273373737".freeze unless defined?(T3)

    before(:all) do
      @pg = PG.connect(ENV["GFC64_PG_URL"])
      @pg.exec("SET client_min_messages = warning")
      @pg.exec("BEGIN")
      @pg.exec(File.read(SQL_FILE))
    end

    after(:all) do
      @pg.exec("ROLLBACK")
      @pg.close
    end

    def value(sql, *params)
      @pg.exec_params(sql, params).getvalue(0, 0)
    end

    def ff1(key_hex, tweak_hex, radix, len, x, decrypt: false)
      value("SELECT gfc64_ff1(decode($1, 'hex'), decode($2, 'hex'), $3, $4, $5, $6)",
            key_hex, tweak_hex, radix, len, x.to_s, decrypt).to_i
    end

    [
      [1, K128, 10, "", "0123456789", "2433477484"],
      [2, K128, 10, T2, "0123456789", "6124200773"],
      [3, K128, 36, T3, "0123456789abcdefghi", "a9tv40mll9kdu509eum"],
      [4, K192, 10, "", "0123456789", "2830668132"],
      [5, K192, 10, T2, "0123456789", "2496655549"],
      [6, K192, 36, T3, "0123456789abcdefghi", "xbj3kv35jrawxv32ysr"],
      [7, K256, 10, "", "0123456789", "6657667009"],
      [8, K256, 10, T2, "0123456789", "1001623463"],
      [9, K256, 36, T3, "0123456789abcdefghi", "xs8a0azh2avyalyzuwd"],
    ].each do |sample, key, radix, tweak, plain, cipher|
      it "matches NIST FF1 sample #{sample} both ways" do
        pt = plain.to_i(radix)
        ct = cipher.to_i(radix)
        expect(ff1(key, tweak, radix, plain.length, pt)).to eq(ct)
        expect(ff1(key, tweak, radix, plain.length, ct, decrypt: true)).to eq(pt)
      end
    end

    it "gives exactly the gem's FF1 + Crockford32 codes" do
      key = GFC64::FF1.generate_key(hex: true)
      ruby = GFC64::FF1.new([key].pack("H*"), radix: 32, length: 8, tweak: "orders")
      fmt = GFC64::Format::Crockford32.new(length: 8, group: 4)
      tweak_hex = "orders".unpack1("H*")
      [1, 2, 3, 42, 1_000_000, 2**40 - 1].concat(Array.new(50) { rand(2**40) }).each do |n|
        code = value("SELECT gfc64_crockford_encode(gfc64_ff1(decode($1, 'hex'), decode($2, 'hex'), 32, 8, $3), 8, 4)",
                     key, tweak_hex, n.to_s)
        expect(code).to eq(fmt.encode(ruby.encrypt(n)))
      end
    end

    it "decodes Crockford forgivingly and returns NULL for anything else" do
      n = value("SELECT gfc64_crockford_decode('TCNH-R99B', 8)")
      expect(value("SELECT gfc64_crockford_decode('tcnh r99b', 8)")).to eq(n)
      expect(value("SELECT gfc64_crockford_decode('TCNH-R99B', 8) = gfc64_crockford_decode('tcnh-r99b', 8)")).to eq("t")
      expect(n.to_i).to eq(GFC64::Format::Crockford32.new(length: 8).decode("TCNH-R99B"))
      %w[UUUUUUUU TCNHR99 TCNHR99BX].each do |bad|
        expect(value("SELECT gfc64_crockford_decode($1, 8)", bad)).to be_nil
      end
    end

    it "fills codes in a BEFORE INSERT trigger, matching has_code, for any insert path" do
      key = GFC64.generate_key
      @pg.exec_params("INSERT INTO gfc64_keys VALUES ('spec', decode($1, 'hex'))", [key])
      @pg.exec("CREATE TEMPORARY TABLE spec_invoices (id bigserial PRIMARY KEY, number text NOT NULL UNIQUE, note text)")
      @pg.exec(<<~SQL)
        CREATE TRIGGER spec_invoices_number BEFORE INSERT ON spec_invoices FOR EACH ROW
          EXECUTE FUNCTION gfc64_assign_code('number', 'spec', 'spec_invoices.number', 'APP-', '8', '4')
      SQL
      @pg.exec("INSERT INTO spec_invoices (note) SELECT 'bulk' FROM generate_series(1, 50)")
      @pg.exec("INSERT INTO spec_invoices (note, number) VALUES ('hand-set', 'APP-0000-0001')")
      rows = @pg.exec("SELECT id, number, note FROM spec_invoices ORDER BY id").to_a

      ff1 = GFC64::FF1.new([key].pack("H*"), radix: 32, length: 8, tweak: "spec_invoices.number")
      fmt = GFC64::Format::Crockford32.new(length: 8, group: 4)
      rows.select { |r| r["note"] == "bulk" }.each do |r|
        expect(r["number"]).to eq("APP-" + fmt.encode(ff1.encrypt(r["id"].to_i)))
      end
      expect(rows.find { |r| r["note"] == "hand-set" }["number"]).to eq("APP-0000-0001")
    end

    it "keeps the key table away from other roles" do
      expect(value("SELECT has_table_privilege('public', 'gfc64_keys', 'SELECT')")).to eq("f")
      expect(value("SELECT has_function_privilege('public', 'gfc64_assign_code()', 'EXECUTE')")).to eq("f")
    end
  end
end
