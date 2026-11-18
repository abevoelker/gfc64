RSpec.describe GFC64::FF1 do
  # NIST's FF1 sample vectors (SP 800-38G examples, FF1samples.pdf).
  DIGITS36 = "0123456789abcdefghijklmnopqrstuvwxyz".freeze
  K128 = "2B7E151628AED2A6ABF7158809CF4F3C".freeze
  K192 = (K128 + "EF4359D8D580AA4F").freeze
  K256 = (K192 + "7F036D6F04FC6A94").freeze
  T2 = "39383736353433323130".freeze
  T3 = "3737373770717273373737".freeze
  NIST_SAMPLES = [
    [1, K128, 10, "", "0123456789", "2433477484"],
    [2, K128, 10, T2, "0123456789", "6124200773"],
    [3, K128, 36, T3, "0123456789abcdefghi", "a9tv40mll9kdu509eum"],
    [4, K192, 10, "", "0123456789", "2830668132"],
    [5, K192, 10, T2, "0123456789", "2496655549"],
    [6, K192, 36, T3, "0123456789abcdefghi", "xbj3kv35jrawxv32ysr"],
    [7, K256, 10, "", "0123456789", "6657667009"],
    [8, K256, 10, T2, "0123456789", "1001623463"],
    [9, K256, 36, T3, "0123456789abcdefghi", "xs8a0azh2avyalyzuwd"],
  ].freeze

  # (plain defs: CI still runs Ruby 2.4)
  def digits(s)
    s.chars.map { |c| DIGITS36.index(c) }
  end

  def text(ds)
    ds.map { |d| DIGITS36[d] }.join
  end

  NIST_SAMPLES.each do |sample, key, radix, tweak, plain, cipher|
    it "matches NIST FF1 sample #{sample} (AES-#{key.length * 4}, radix #{radix}#{tweak.empty? ? '' : ', tweak'})" do
      ff1 = described_class.new([key].pack("H*"), radix: radix, tweak: [tweak].pack("H*"), insecure_test_key: true)
      expect(text(ff1.encrypt_digits(digits(plain)))).to eq(cipher)
      expect(text(ff1.decrypt_digits(digits(cipher)))).to eq(plain)
    end
  end

  let(:key) { SecureRandom.bytes(32) }

  context "Integer values" do
    let(:ff1) { described_class.new(key, radix: 32, length: 8, tweak: "invoices") }

    it "round-trips and stays below radix**length" do
      expect(ff1.domain_size).to eq(2**40)
      property_of { range(0, 2**40 - 1) }.check(2_000) { |n|
        e = ff1.encrypt(n)
        expect(e).to be_between(0, 2**40 - 1)
        expect(ff1.decrypt(e)).to eq(n)
      }
    end

    it "never repeats over a counter's first 20,000 values" do
      encrypted = (1..20_000).map { |n| ff1.encrypt(n) }
      expect(encrypted.uniq.size).to eq(20_000)
    end

    it "pairs with Crockford base32 into 8-character codes" do
      fmt = GFC64::Format::Crockford32.new(length: 8, group: 4)
      code = fmt.encode(ff1.encrypt(42))
      expect(code).to match(/\A[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}\z/)
      expect(ff1.decrypt(fmt.decode(code.downcase))).to eq(42)
    end

    it "works in bases that aren't powers of two (a 31-character alphabet)" do
      fmt = GFC64::Format::Alphabet.new("ABCDEFGHJKMNPQRSTUVWXYZ23456789", length: 8)
      ff31 = described_class.new(key, radix: fmt.radix, length: 8)
      expect(ff31.domain_size).to eq(31**8)
      code = fmt.encode(ff31.encrypt(123_456))
      expect(code.length).to eq(8)
      expect(ff31.decrypt(fmt.decode(code))).to eq(123_456)
    end
  end

  context "tweaks" do
    it "gives unrelated results per tweak and needs the same tweak to decrypt" do
      a = described_class.new(key, radix: 32, length: 8, tweak: "invoices")
      b = described_class.new(key, radix: 32, length: 8, tweak: "orders")
      same = (1..1_000).count { |n| a.encrypt(n) == b.encrypt(n) }
      expect(same).to eq(0)
      expect(b.decrypt(a.encrypt(5))).not_to eq(5)
    end

    it "takes a per-call tweak" do
      ff1 = described_class.new(key, radix: 10, length: 10)
      e = ff1.encrypt(99, tweak: "x")
      expect(ff1.decrypt(e, tweak: "x")).to eq(99)
      expect(e).not_to eq(ff1.encrypt(99))
    end
  end

  context "keys" do
    it "generates random AES-256 keys, raw or hex" do
      raw = described_class.generate_key
      hex = described_class.generate_key(hex: true)
      expect(raw.bytesize).to eq(32)
      expect(hex).to match(/\A\h{64}\z/)
      expect { described_class.new([hex].pack("H*"), radix: 10) }.not_to raise_error
      expect(described_class.generate_key).not_to eq(raw)
    end

    it "refuses NIST's sample keys and non-random keys unless told it's a test" do
      [K128, K192, K256].each do |k|
        expect { described_class.new([k].pack("H*"), radix: 10) }.to raise_error(ArgumentError, /published example key/)
      end
      expect { described_class.new("k" * 32, radix: 10) }.to raise_error(ArgumentError, /isn't random/)
      expect { described_class.new([K128].pack("H*"), radix: 10, insecure_test_key: true) }.not_to raise_error
    end
  end

  context "invalid arguments" do
    it "needs an AES-128/192/256 key" do
      expect { described_class.new("short", radix: 10) }.to raise_error(ArgumentError, /16, 24 or 32 bytes/)
    end

    it "enforces radix range and the 1,000,000-value minimum domain" do
      expect { described_class.new(key, radix: 1) }.to raise_error(ArgumentError, /radix/)
      expect { described_class.new(key, radix: 65_537) }.to raise_error(ArgumentError, /radix/)
      expect { described_class.new(key, radix: 10, length: 5) }.to raise_error(ArgumentError, /1000000/)
      expect { described_class.new(key, radix: 10, length: 6) }.not_to raise_error
      expect { described_class.new(key, radix: 10).encrypt_digits([1, 2, 3]) }.to raise_error(ArgumentError, /1000000/)
    end

    it "rejects bad digits, out-of-range numbers and a missing length" do
      ff1 = described_class.new(key, radix: 10, length: 6)
      expect { ff1.encrypt_digits([1, 2, 3, 4, 5, 10]) }.to raise_error(ArgumentError, /digit/)
      expect { ff1.encrypt(1_000_000) }.to raise_error(ArgumentError, /0 to 999999/)
      expect { described_class.new(key, radix: 10).encrypt(5) }.to raise_error(ArgumentError, /length/)
      expect { described_class.new(key, radix: 10, tweak: 5) }.to raise_error(ArgumentError, /tweak/)
    end
  end
end
