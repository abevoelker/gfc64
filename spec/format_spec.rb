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

    it "normalizes typed codes to the canonical form, and decodes strictly on request" do
      grouped = described_class.new(bits: 40, group: 4)
      code = grouped.encode(gfc.encrypt(7))
      typed = code.downcase.tr("-", " ").tr("0", "o").tr("1", "l")
      expect(grouped.normalize(typed)).to eq(code)
      expect(grouped.normalize(" #{code} ")).to eq(code)
      expect(grouped.normalize("not a code")).to eq("N0TA-C0DE") # really is one: 8 valid characters
      expect(grouped.normalize("UUUU-UUUU")).to be_nil
      expect(grouped.normalize(nil)).to be_nil
      expect(grouped.canonical?(code)).to be true
      [typed, code.delete("-"), " #{code}", code.downcase].each do |variant|
        next if variant == code
        expect(grouped.canonical?(variant)).to be false
        expect(grouped.decode(variant)).to eq(grouped.decode(code))
        expect { grouped.decode(variant, strict: true) }.to raise_error(ArgumentError, /canonical form/)
        expect(grouped.valid?(variant, strict: true)).to be false
      end
      expect(grouped.decode(code, strict: true)).to eq(gfc.encrypt(7))
    end

    describe "check: true" do
      let(:fmt) { described_class.new(length: 8, group: [4, 5], check: true) }
      let(:alpha) { described_class::ALPHABET.chars }

      it "adds a 9th character from the alphabet, grouped 4 + 5" do
        code = fmt.encode(gfc.encrypt(7))
        expect(code).to match(/\A[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{5}\z/)
        expect(fmt.code_length).to eq(9)
        expect(fmt.length).to eq(8)
        expect(fmt.check?).to be true
        expect(fmt.decode(code)).to eq(gfc.encrypt(7))
        expect(fmt.decode(code.downcase.tr("-", " "))).to eq(gfc.encrypt(7))
        expect(fmt.normalize(code.delete("-").downcase)).to eq(code)
        expect(fmt.decode(code, strict: true)).to eq(gfc.encrypt(7))
      end

      it "catches every single wrong character and every swap of neighbours" do
        200.times do
          raw = fmt.encode(rand(2**40)).delete("-")
          raw.length.times do |i|
            (alpha - [raw[i]]).each do |c|
              typo = raw.dup
              typo[i] = c
              expect { fmt.decode(typo) }.to raise_error(GFC64::Format::Alphabet::CheckError, /typo/)
            end
            next if i == raw.length - 1 || raw[i] == raw[i + 1]

            swapped = raw.dup
            swapped[i], swapped[i + 1] = raw[i + 1], raw[i]
            expect(fmt.valid?(swapped)).to be false
          end
        end
      end

      it "still forgives look-alikes, which aren't typos" do
        raw = fmt.encode(0).delete("-")
        expect(fmt.decode(raw.tr("0", "O"))).to eq(0)
      end

      it "rejects a code without its check character, and alphabets it can't check" do
        expect { fmt.decode(described_class.new(length: 8).encode(5)) }.to raise_error(ArgumentError, /9 characters/)
        expect { GFC64::Format::Alphabet.new("0123456789", bits: 8, check: true) }.to raise_error(ArgumentError, /power of two/)
        expect { GFC64::Format::Alphabet.new("01", bits: 8, check: true) }.to raise_error(ArgumentError, /power of two/)
        expect(GFC64::Format::Alphabet.new("0123", bits: 8, check: true).encode(200).length).to eq(5)
      end
    end

    it "groups by a list of sizes, the last repeating" do
      expect(described_class.new(length: 8, group: [3, 2]).encode(0)).to eq("000-00-00-0")
      expect { described_class.new(length: 8, group: []) }.to raise_error(ArgumentError, /group/)
      expect { described_class.new(length: 8, group: [4, 0]) }.to raise_error(ArgumentError, /group/)
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
      expect { fmt.encode(256) }.to raise_error(ArgumentError, /0 to 255/)
      expect { fmt.decode(nil) }.to raise_error(ArgumentError)
    end
  end
end
