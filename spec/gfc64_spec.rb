RSpec.describe GFC64 do
  it "has a version number" do
    expect(GFC64::VERSION).not_to be nil
  end

  let(:key) { "ffb5e3600fc27924f97dc055440403b10ce97160261f2a87eee576584cf942e5" }
  let(:gfc) { GFC64.new(key) }

  it "encrypts and decrypts a number" do
    expect(gfc.encrypt(1234567890)).to eq(11276442059044733597)
    expect(gfc.decrypt(11276442059044733597)).to eq(1234567890)

    expect(gfc.encrypt(1)).to eq(4552956331295818987)
    expect(gfc.decrypt(4552956331295818987)).to eq(1)
  end
end
