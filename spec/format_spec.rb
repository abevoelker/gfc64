RSpec.describe GFC64::Format do
  let(:key) { SecureRandom.hex(32) }
  let(:gfc) { GFC64.new(key, bits: 40) }

  describe GFC64::Format::Crockford32 do
    let(:fmt) { described_class.new(bits: 40) }

    it "is exactly 8 characters at 40 bits, padded with zeros" do
      expect(fmt.length).to eq(8)
      expect(fmt.encode(0)).to eq("00000000")
      expect(fmt.encode(2**40 - 1)).to eq("ZZZZZZZZ")
      expect(fmt.encode(32)).to eq("00000010")
    end

    it "round-trips encrypted counters" do
      property_of { range(0, 2**40 - 1) }.check(5_000) { |n|
        code = fmt.encode(gfc.encrypt(n))
        expect(code).to match(/\A[0-9A-HJKMNP-TV-Z]{8}\z/)
        expect(gfc.decrypt(fmt.decode(code))).to eq(n)
      }
    end

    it "reads lowercase, O as 0, I and L as 1, and ignores hyphens and spaces" do
      code = fmt.encode(gfc.encrypt(7))
      typed = code.downcase.tr("0", "o").tr("1", "l").insert(4, "- ")
      expect(fmt.decode(typed)).to eq(fmt.decode(code))
    end

    it "groups output with a separator" do
      grouped = described_class.new(bits: 40, group: 4)
      code = grouped.encode(gfc.encrypt(7))
      expect(code).to match(/\A[0-9A-Z]{4}-[0-9A-Z]{4}\z/)
      expect(grouped.decode(code)).to eq(gfc.encrypt(7))
    end

    it "rejects U, wrong lengths and junk" do
      expect { fmt.decode("UUUUUUUU") }.to raise_error(ArgumentError, /valid character/)
      expect { fmt.decode("1234567") }.to raise_error(ArgumentError, /8 characters/)
      expect { fmt.decode("123456789") }.to raise_error(ArgumentError, /8 characters/)
      expect(fmt.valid?("ABCD-EFGH")).to be true
      expect(fmt.valid?("ABCD-EFG!")).to be false
    end
  end

  describe GFC64::Format::Base58 do
    let(:fmt) { described_class.new(bits: 40) }

    it "is 7 characters at 40 bits and case-sensitive" do
      expect(fmt.length).to eq(7)
      code = fmt.encode(gfc.encrypt(99))
      expect(code).to match(/\A[1-9A-HJ-NP-Za-km-z]{7}\z/)
      expect(gfc.decrypt(fmt.decode(code))).to eq(99)
      expect(fmt.decode("111111a")).not_to eq(fmt.decode("111111A"))
    end

    it "rejects values above the width (not every 7-character string is a 40-bit number)" do
      expect { fmt.decode("zzzzzzz") }.to raise_error(ArgumentError, /out of range/)
    end

    it "rejects 0, O, I and l" do
      %w[0 O I l].each do |c|
        expect { fmt.decode("1111111".sub("1", c)) }.to raise_error(ArgumentError, /valid character/)
      end
    end
  end

  describe GFC64::Format::Decimal do
    it "is 13 digits at 40 bits" do
      fmt = described_class.new(bits: 40)
      expect(fmt.length).to eq(13)
      expect(fmt.encode(42)).to eq("0000000000042")
      expect(fmt.decode("0000000000042")).to eq(42)
    end
  end

  describe GFC64::Format::Alphabet do
    it "builds a custom alphabet, with aliases" do
      # 31 characters: no 0/O, 1/I/L.
      fmt = described_class.new("ABCDEFGHJKMNPQRSTUVWXYZ23456789", bits: 40, case_sensitive: false)
      expect(fmt.length).to eq(9) # 31^8 < 2^40 <= 31^9
      n = gfc.encrypt(5)
      expect(fmt.decode(fmt.encode(n).downcase)).to eq(n)
    end

    it "drops a custom separator on input" do
      fmt = described_class.new("0123456789", bits: 16, group: 2, separator: "_")
      expect(fmt.encode(65_535)).to eq("65_53_5")
      expect(fmt.decode("65_53_5")).to eq(65_535)
    end

    it "rejects bad alphabets and aliases" do
      expect { described_class.new("AAB", bits: 8) }.to raise_error(ArgumentError)
      expect { described_class.new("A", bits: 8) }.to raise_error(ArgumentError)
      expect { described_class.new("AB", bits: 8, aliases: { "C" => "D" }) }.to raise_error(ArgumentError, /alias/)
    end

    it "rejects numbers outside the width and non-strings" do
      fmt = described_class.new("01", bits: 8)
      expect { fmt.encode(256) }.to raise_error(ArgumentError, /8-bit/)
      expect { fmt.decode(nil) }.to raise_error(ArgumentError)
    end
  end
end
