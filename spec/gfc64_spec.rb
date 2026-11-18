# Pinned when bits: was added (0.2.0); a change here would renumber every
# 40-bit value already stored somewhere.
KNOWN_40_BIT = [396152076914, 535920561349, 936767000312, 674877033606].freeze

RSpec.describe GFC64 do
  it "has a version number" do
    expect(GFC64::VERSION).not_to be nil
  end

  let(:gfc) { GFC64.new(key) }

  context "known good values" do
    let(:key) { "ffb5e3600fc27924f97dc055440403b10ce97160261f2a87eee576584cf942e5" }
    let(:gfc) { GFC64.new(key, insecure_test_key: true) }

    it "encrypts and decrypts a number" do
      expect(gfc.encrypt(1234567890)).to eq(11276442059044733597)
      expect(gfc.decrypt(11276442059044733597)).to eq(1234567890)

      expect(gfc.encrypt(1)).to eq(4552956331295818987)
      expect(gfc.decrypt(4552956331295818987)).to eq(1)
    end

    it "gives the same 64-bit results when bits: 64 is passed explicitly" do
      expect(GFC64.new(key, bits: 64, insecure_test_key: true).encrypt(1)).to eq(4552956331295818987)
      expect(GFC64.new(key, bits: 64, insecure_test_key: true).rounds).to eq(3)
    end

    it "keeps 40-bit values stable across versions" do
      gfc40 = GFC64.new(key, bits: 40, insecure_test_key: true)
      expect([1, 2, 3, 1234567890].map { |n| gfc40.encrypt(n) }).to eq(KNOWN_40_BIT)
    end
  end

  context "random property-based testing" do
    let(:key) { SecureRandom.hex(32) }

    it "encrypts and decrypts a number" do
      property_of {
        range(0, 2**64 - 1)
      }.check(50_000) { |x|
        e_x = gfc.encrypt(x)
        expect(e_x).to be_a(Integer)
        expect(e_x).to be_between(0, 2**64 - 1)
        d_e_x = gfc.decrypt(e_x)
        expect(d_e_x).to eq(x)
      }
    end

    [16, 24, 32, 40, 48, 56].each do |bits|
      it "round-trips #{bits}-bit numbers and stays within #{bits} bits" do
        gfc_n = GFC64.new(key, bits: bits)
        property_of {
          range(0, 2**bits - 1)
        }.check(5_000) { |x|
          e_x = gfc_n.encrypt(x)
          expect(e_x).to be_between(0, 2**bits - 1)
          expect(gfc_n.decrypt(e_x)).to eq(x)
        }
      end
    end
  end

  context "narrower widths" do
    let(:key) { SecureRandom.hex(32) }

    it "is a permutation: every 16-bit value maps to a different 16-bit value" do
      gfc16 = GFC64.new(key, bits: 16)
      encrypted = (0...2**16).map { |n| gfc16.encrypt(n) }
      expect(encrypted.uniq.size).to eq(2**16)
      expect(encrypted.minmax).to eq([0, 2**16 - 1])
      expect(encrypted.each_with_index.all? { |e, n| gfc16.decrypt(e) == n }).to be true
    end

    it "never repeats for a counter's first 100,000 values at 40 bits" do
      gfc40 = GFC64.new(key, bits: 40)
      encrypted = (1..100_000).map { |n| gfc40.encrypt(n) }
      expect(encrypted.uniq.size).to eq(100_000)
      expect(encrypted.max).to be < 2**40
    end

    it "doesn't keep sequential inputs close together" do
      gfc40 = GFC64.new(key, bits: 40)
      gaps = (1..1_000).each_cons(2).map { |a, b| (gfc40.encrypt(b) - gfc40.encrypt(a)).abs }
      expect(gaps.count { |g| g < 2**20 }).to be < 10 # adjacent outputs within 2^20 of each other: ~0.1% by chance
    end

    it "gives unrelated results for the same key at different widths" do
      a = GFC64.new(key, bits: 40).encrypt(12_345)
      b = GFC64.new(key, bits: 48).encrypt(12_345) & (2**40 - 1)
      expect(a).not_to eq(b)
    end

    it "uses 10 rounds by default below 64 bits, and accepts a rounds override" do
      expect(GFC64.new(key, bits: 40).rounds).to eq(10)
      gfc = GFC64.new(key, bits: 40, rounds: 12)
      expect(gfc.rounds).to eq(12)
      expect(gfc.decrypt(gfc.encrypt(42))).to eq(42)
    end

    it "reports the block size in bytes" do
      expect(GFC64.new(key, bits: 40).block_size).to eq(5)
      expect(GFC64.new(key, bits: 18).block_size).to eq(Rational(9, 4))
    end
  end

  context "tweaks" do
    let(:key) { SecureRandom.hex(32) }

    it "leaves results unchanged when no tweak is given (64-bit and narrower)" do
      known = "ffb5e3600fc27924f97dc055440403b10ce97160261f2a87eee576584cf942e5"
      expect(GFC64.new(known, tweak: nil, insecure_test_key: true).encrypt(1)).to eq(4552956331295818987)
      expect([1, 2, 3, 1234567890].map { |n| GFC64.new(known, bits: 40, insecure_test_key: true).encrypt(n) }).to eq(KNOWN_40_BIT)
    end

    it "gives unrelated ciphers under one key, each still a permutation" do
      a = GFC64.new(key, bits: 16, tweak: "invoices")
      b = GFC64.new(key, bits: 16, tweak: "orders")
      plain = GFC64.new(key, bits: 16)
      ea = (0...2**16).map { |n| a.encrypt(n) }
      eb = (0...2**16).map { |n| b.encrypt(n) }
      expect(ea.uniq.size).to eq(2**16)
      expect(eb.uniq.size).to eq(2**16)
      expect(ea.zip(eb).count { |x, y| x == y }).to be < 10 # ~1 by chance
      expect(ea.each_with_index.count { |x, n| x == plain.encrypt(n) }).to be < 10
      expect(ea.each_with_index.all? { |x, n| a.decrypt(x) == n }).to be true
    end

    it "needs the same tweak to decrypt" do
      e = GFC64.new(key, bits: 40, tweak: "invoices").encrypt(42)
      expect(GFC64.new(key, bits: 40, tweak: "invoices").decrypt(e)).to eq(42)
      expect(GFC64.new(key, bits: 40, tweak: "orders").decrypt(e)).not_to eq(42)
    end

    it "works at 64 bits and treats an empty tweak as a tweak" do
      t = GFC64.new(key, tweak: "x")
      expect(t.decrypt(t.encrypt(2**63))).to eq(2**63)
      expect(t.encrypt(1)).not_to eq(GFC64.new(key).encrypt(1))
      expect(GFC64.new(key, bits: 40, tweak: "").encrypt(1)).not_to eq(GFC64.new(key, bits: 40).encrypt(1))
    end

    it "keeps the tweak and the width apart (length-prefixed)" do
      a = GFC64.new(key, bits: 40, tweak: "ab").encrypt(7)
      b = GFC64.new(key, bits: 40, tweak: "a").encrypt(7)
      expect(a).not_to eq(b)
    end

    it "rejects a non-String tweak" do
      expect { GFC64.new(key, tweak: 123) }.to raise_error(ArgumentError, /tweak/)
    end
  end

  context "keys" do
    it "generates random 64-hex-character keys" do
      k = GFC64.generate_key
      expect(k).to match(/\A\h{64}\z/)
      expect(GFC64.generate_key).not_to eq(k)
      expect { GFC64.new(k) }.not_to raise_error
    end

    it "refuses the README's example key and NIST's test keys unless told it's a test" do
      readme = "ffb5e3600fc27924f97dc055440403b10ce97160261f2a87eee576584cf942e5"
      expect { GFC64.new(readme) }.to raise_error(ArgumentError, /published example key/)
      expect { GFC64.new(readme.upcase) }.to raise_error(ArgumentError, /published example key/)
      expect { GFC64.new("2B7E151628AED2A6ABF7158809CF4F3C") }.to raise_error(ArgumentError, /published example key/)
      expect { GFC64.new(readme, insecure_test_key: true) }.not_to raise_error
    end

    it "refuses keys that repeat one or two bytes, including empty ones" do
      ["", "k" * 32, "ab" * 16, "\0" * 16].each do |k|
        expect { GFC64.new(k) }.to raise_error(ArgumentError, /isn't random/)
      end
      expect { GFC64.new(nil) }.to raise_error(ArgumentError, /String/)
    end
  end

  context "invalid arguments" do
    let(:key) { SecureRandom.hex(32) }

    it "rejects odd, too small or too large widths" do
      [15, 41, 14, 66, 0, "40", nil].each do |bits|
        expect { GFC64.new(key, bits: bits) }.to raise_error(ArgumentError, /bits must be an even Integer/)
      end
    end

    it "rejects numbers outside the width" do
      gfc40 = GFC64.new(key, bits: 40)
      expect { gfc40.encrypt(2**40) }.to raise_error(ArgumentError, /40-bit/)
      expect { gfc40.decrypt(-1) }.to raise_error(ArgumentError, /40-bit/)
      expect { gfc40.encrypt(1.0) }.to raise_error(ArgumentError)
    end

    it "rejects a non-positive rounds count" do
      expect { GFC64.new(key, rounds: 0) }.to raise_error(ArgumentError, /rounds/)
    end
  end
end
