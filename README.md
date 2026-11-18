# GFC64

Turn sequential database IDs into short, unguessable codes, and back
again, without storing anything extra.

Say your app has URLs like these, which tell anyone how many customers you
have and invite guessing the next one:

`/customers/1`

`/customers/2`

With this gem the same records get paths like these instead, while the
database keeps its ordinary auto-incrementing IDs and indexes:

`/customers/BQZbwjf` (the app decodes this back to customer 1)

`/customers/F5WTxhS` (customer 2)

```ruby
class Customer < ApplicationRecord
  has_public_id bits: 40, format: GFC64::Format::Base58.new(bits: 40)
end

customer_path(customer)                       # => "/customers/BQZbwjf"
Customer.find_by_public_id!(params[:id])      # => customer 1 (or a 404)
```

The same goes for codes people read aloud and type, such as invoice numbers:

```ruby
class Invoice < ApplicationRecord
  has_public_id cipher: :ff1, prefix: "APP-",
                format: GFC64::Format::Crockford32.new(length: 8, group: 4)
end

invoice.public_id                                 # => "APP-TCNH-R99B"
Invoice.find_by_public_id!("app tcnh r99b")       # any case or spacing
```

(When a code must never change once issued, `has_code` stores it instead;
see [Computed or stored?](#computed-or-stored).)

Under the hood, each number is encrypted with a secret key into another
number of the same size: no two IDs ever share a code, and without the key
nobody can work out the next one. Two ciphers are included: NIST's
[FF1][sp800-38g] format-preserving cipher, and a [Generalized Feistel
Cipher][paper] over 16 to 64-bit integers. The codes come from formatters
for [Crockford base32][crockford], base58, digits, or your own alphabet.

(The example codes above are illustrations; yours depend on your key.)

## Installation

Add to your `Gemfile`:

```ruby
gem "gfc64"
```

## Rails Usage

Every ActiveRecord model gets two class methods: `has_public_id` (a code
computed from the primary key whenever it's needed, nothing stored) and
`has_code` (a code made once from the id and stored in a column).
Outside Rails, `include GFC64::Model`.

### The key

Set it once; it's read the first time it's needed, so asset builds and
consoles without the secret still boot:

```ruby
# config/initializers/gfc64.rb, or nothing at all to use ENV["GFC64_KEY"]
GFC64.configure { |c| c.key = Rails.application.credentials.gfc64_key }
```

The key is 64 hex characters from `GFC64.generate_key`; use a different one
per environment and keep it. A missing key raises `GFC64::KeyMissing` naming
the setting.

### Computed codes and public ids (`has_public_id`)

```ruby
class Customer < ApplicationRecord
  has_public_id bits: 40, format: GFC64::Format::Base58.new(bits: 40)
end

customer_path(customer)                  # => "/customers/BQZbwjf"
customer.public_id                       # => "BQZbwjf"

# app/controllers/customers_controller.rb
@customer = Customer.find_by_public_id!(params[:id])
```

- `find_by_public_id!` raises `ActiveRecord::RecordNotFound` (so a 404) for
  anything that isn't a valid id: wrong characters or length, out of range,
  or no such record. `find_by_public_id` returns nil instead.
- Each model gets its own mapping (the tweak defaults to the table name), so
  Customer 5 and Order 5 have unrelated public ids.
- `bits:` must cover your largest id (40 bits is about 1.1 trillion). Leave
  out `format:` for a plain encrypted number (64-bit by default, as in
  0.1.0), or pass `cipher: :ff1` with a `length:`-based format.
- `prefix:` puts text in front (`"INV-"`); it's optional when decoding, in
  any case or spacing. With FF1 and Crockford base32 that makes
  invoice-style codes from the primary key with nothing stored:

  ```ruby
  has_public_id cipher: :ff1, prefix: "INV-",
                format: GFC64::Format::Crockford32.new(length: 8, group: 4)
  # invoice.public_id => "INV-TCNH-R99B"
  ```
- `param: false` keeps `to_param` as the plain id.
- `guard_find: true` makes `find` raise `GFC64::UnsafeFind` when it's given
  a String that isn't all digits, on the model, its relations and its
  associations (see [Things to know](#things-to-know) for why). It's off by
  default because it overrides `find`.
- Lookups are forgiving by default. Pass `strict: true` to accept only the
  exact canonical form (`find_by_public_id!(value, strict: true)`), and use
  `canonical_public_id(value)` to get that form.

To keep one URL per record while still accepting codes typed by hand,
redirect to the canonical form:

```ruby
def show
  @invoice = Invoice.find_by_public_id!(params[:id])
  redirect_to @invoice, status: :moved_permanently unless params[:id] == @invoice.to_param
end
```

### Computed or stored?

`has_public_id` is the default choice: nothing extra in the database, and
any code decodes straight back to its record. The trade-off is that a code
depends on the key, format, prefix and tweak staying the same: change one
and every code changes with it.

Use `has_code` to store the code when it must never change once it's been
issued:

- it's printed or sent somewhere you can't update (invoices, receipts,
  tickets, a payment provider's records);
- people read it outside your app (reports, CSV exports, SQL, support
  tools) without the key;
- some codes come from elsewhere (imported or hand-entered) and must live
  in the same column;
- you want the option of a new key or format for future records, with old
  codes still valid.

### Stored codes (`has_code`)

For codes that must never change once issued (see above). The code is made
from the record's own auto-incremented id, like `has_public_id`, and then
kept in a column:

```ruby
# migration: one column, no sequence or counter
add_column :invoices, :number, :string, null: false
add_index :invoices, :number, unique: true

class Invoice < ApplicationRecord
  has_code :number, prefix: "APP-",
                    format: GFC64::Format::Crockford32.new(length: 8, group: 4)
end

invoice = Invoice.create!(...)
invoice.number                                   # => "APP-TCNH-R99B"
Invoice.find_by_code!(:number, "app tcnh-r99b")  # any case or spacing, O/I/L, prefix optional
invoice.code_sequence_value(:number)             # => invoice.id (decrypted from the code)
Invoice.normalize_code(:number, "app tcnh r99b") # => "APP-TCNH-R99B"
```

`find_by_code(..., strict: true)` accepts only the stored form.

- On create the id is encrypted with FF1 (any alphabet; `cipher: :feistel`
  for power-of-two ones), formatted, prefixed and stored. A code that's
  already set is kept, and an id you set yourself is used.
- On Postgres the id is read ahead from the table's own sequence, so the
  code goes into the same INSERT and the column can be `NOT NULL`. On other
  databases the code is filled in right after the INSERT, in the same
  transaction, so the column has to allow NULL.
- Reading the id ahead is safe under concurrency: `nextval` hands each
  value out exactly once, and the INSERT supplies it as the id, so the
  table's sequence still advances once per record.
- Codes are assigned by ActiveRecord callbacks, so `create` and `save` set
  them but `insert_all`, `upsert_all` and raw SQL don't. For bulk inserts,
  reserve ids from the sequence and set the column yourself with
  `Invoice.generate_code(:number, id)`.
- Stored codes never change, even if you later change the format or key:
  existing records keep theirs.
- The code is assigned in `before_create`, after validations, so validate
  it in the database (`null: false`, unique index) rather than with
  `validates :number, presence: true`.
- For numbering that's independent of the id, pass `sequence:` a Postgres
  sequence name (`execute "CREATE SEQUENCE invoice_numbers"`) or a callable
  returning the next Integer. Either way, a value used by a transaction
  that rolls back is skipped, so codes can have gaps.
- The tweak defaults to `"table.column"`, so a stored code never matches
  the same record's `has_public_id`, and two coded columns never share a
  mapping.

### Upgrading from `GFC64::ActiveRecord`

The 0.1.0 mixin (`include GFC64::ActiveRecord[gfc]`, `find_gfc`) still works
and now accepts the String from `params` (bad values raise `RecordNotFound`
instead of `ArgumentError`). It's deprecated in favor of `has_public_id`. To
keep the URLs you already have, set the same key with `GFC64.configure` (it
  must be 64 hex characters, as `SecureRandom.hex(32)` made) and
use `has_public_id tweak: false`: no format, 64 bits and no tweak give the
same numbers as the old mixin.

## General Usage

Outside Rails (or for anything the Rails helpers don't cover), use the
ciphers and formatters directly.

**1. Make a key once and keep it secret.** Store it like any other
credential (an environment variable, Rails credentials, a secrets manager),
one per environment:

```ruby
require "gfc64"

GFC64.generate_key # => "9b1f0c…" (64 hex characters; run once, then store it)
key = ENV.fetch("GFC64_KEY")
```

**2. Short codes, e.g. order numbers.** FF1 encrypts a counter into 8
base-32 digits, and Crockford base32 writes them out:

```ruby
orders = GFC64::FF1.new([key].pack("H*"), radix: 32, length: 8, tweak: "orders")
codes  = GFC64::Format::Crockford32.new(length: 8, group: 4)

number = codes.encode(orders.encrypt(1042)) # => e.g. "F4CP-ZTDP"
orders.decrypt(codes.decode("f4cp ztdp"))   # => 1042 (any case and spacing)

codes.valid?("F4CP-ZTDU")                   # => false (U isn't in the alphabet)
codes.decode("F4CP-ZTD")                    # raises ArgumentError (7 characters)
```

**3. Public ids in URLs.** The Feistel cipher at 40 bits, shown in base58:

```ruby
customers = GFC64.new(key, bits: 40, tweak: "customers")
ids       = GFC64::Format::Base58.new(bits: 40)

ids.encode(customers.encrypt(1))         # => e.g. "MFNmYL5"
customers.decrypt(ids.decode("MFNmYL5")) # => 1
```

**4. Full 64-bit integers** (what 0.1.0 did):

```ruby
gfc = GFC64.new(key)
gfc.encrypt(1)                    # => e.g. 10372255740914870282
gfc.decrypt(10372255740914870282) # => 1
```

The outputs above depend on the key, so yours will differ. The sections
below cover each piece: keys, widths, tweaks, FF1 and the formats.

## Keys

The key is what makes the output unpredictable. Two apps using the same
tweak (say `"invoices"`) get unrelated sequences as long as each has its
own random key; anyone who has a key can compute every value under it.

- Generate keys, don't write them: `GFC64.generate_key` (64 hex characters)
  for `GFC64.new`, `GFC64::FF1.generate_key` (32 raw bytes, or
  `generate_key(hex: true)`) for FF1. Never derive one from a password.
- Keep it with your other secrets (an env var, a secrets manager), one per
  environment, and don't change it: a new key changes every value.
- The README's example key, NIST's FF1 test keys and keys that repeat one or
  two bytes (`"k" * 32`, `""`) raise `ArgumentError`. Pass
  `insecure_test_key: true` to use one in tests.
- If the key leaks, past and future values become computable. When values
  must stay unguessable even then, use random values with a uniqueness check
  instead of a cipher.

### Upgrading from 0.1.0

64-bit values are unchanged. The only difference is that the example key and
non-random keys now raise; generate a new key, or pass
`insecure_test_key: true` where a test relies on one.

## Narrower numbers (`bits:`)

64-bit results are long (up to 20 digits). For something people read and
type, such as an invoice or order number, encrypt into a narrower range
instead. `bits:` takes any even width from 16 to 64; every number from 0 to
`2**bits - 1` encrypts to a different number in that same range:

```ruby
gfc = GFC64.new(key, bits: 40)
gfc.encrypt(1) # => a number below 2**40 (1,099,511,627,776)
gfc.decrypt(gfc.encrypt(1)) # => 1
```

40 bits is exactly 8 characters of [Crockford base32][crockford], so a
counter can become a short, unguessable code like `7KQMR3XH`.

- Below 64 bits the default is 10 rounds (NIST's FF1 uses 10), since each
  half is smaller; pass `rounds:` to change it. 64-bit keeps 3, so values
  encrypted with 0.1.0 are unchanged.
- The width is mixed into the round keys: the same key at 40 and 48 bits
  gives unrelated ciphers.
- Pick a width you can keep. Changing `bits:` (or the key) changes every
  encrypted value, so store the encrypted value if it's printed or sent
  anywhere, and start a new width for new records rather than re-encrypting
  old ones.
- Small widths are small domains: at 16 bits there are only 65,536
  values, so don't rely on unguessability there.

## Tweaks (`tweak:`)

A tweak is a public string that picks one of many independent ciphers under
the same key, the way FF1 and other [tweakable block ciphers][tweakable]
use one:

```ruby
invoices = GFC64.new(key, bits: 40, tweak: "invoices")
orders   = GFC64.new(key, bits: 40, tweak: "orders")
invoices.encrypt(42) # unrelated to orders.encrypt(42)
```

- One secret key can serve several kinds of numbers, and knowing one kind's
  codes says nothing about another's.
- A tweak isn't a secret and doesn't need randomness (that's the key's job),
  and it isn't a per-record salt: values are only
  guaranteed collision-free within one key + tweak. Use one fixed tweak per
  kind of number.
- A new tweak (`"invoices-v2"`) starts a fresh sequence without a new key.
- No tweak gives exactly the results from before tweaks existed.

## FF1 (`GFC64::FF1`)

[NIST SP 800-38G][sp800-38g] FF1 is the standard format-preserving cipher:
it encrypts a string of digits in any base (2 to 65,536) into another of the
same length and base, with AES and a tweak. This implementation passes all
nine of NIST's FF1 sample vectors (AES-128/192/256, radix 10 and 36, with and
without tweaks).

```ruby
key = GFC64::FF1.generate_key # 32 random bytes (AES-256); generate_key(hex: true) for storage
ff1 = GFC64::FF1.new(key, radix: 32, length: 8, tweak: "invoices")
fmt = GFC64::Format::Crockford32.new(length: 8, group: 4)

code = fmt.encode(ff1.encrypt(42)) # => e.g. "N4WB-0TQ7"
ff1.decrypt(fmt.decode(code))      # => 42
```

- `radix:` doesn't have to be a power of two: a 31-character alphabet works
  as `FF1.new(key, radix: 31, length: 8)` with
  `Format::Alphabet.new(chars, length: 8)`.
- `encrypt_digits` / `decrypt_digits` work on digit arrays (most significant
  first) of any length the standard allows, as in NIST's examples.
- SP 800-38G Rev. 1 requires at least 1,000,000 possible values
  (`radix**length`); smaller domains are rejected.
- The key is raw bytes; from hex, `[hex].pack("H*")`.

### Which to use

- **FF1** when you want a reviewed standard with published test vectors,
  or a base that isn't a power of two. It takes about 0.1 ms per
  value.
- **`GFC64` (the Feistel cipher)** for 64-bit IDs as in 0.1.0, or when
  speed matters more than a standard. It's faster, but unreviewed (see the
  disclaimer).

## Formatting codes (`GFC64::Format`)

Encrypted numbers are easier to read, type and say aloud as short strings.
`GFC64::Format` turns a number of a given width into a fixed-length string
and back:

```ruby
gfc = GFC64.new(key, bits: 40)
fmt = GFC64::Format::Crockford32.new(bits: 40, group: 4)

code = fmt.encode(gfc.encrypt(1)) # => "BGY8-1YKJ"
gfc.decrypt(fmt.decode(code))     # => 1
gfc.decrypt(fmt.decode("bgy8 lykj")) # => 1 (any case; O→0, I/L→1; spaces and hyphens ignored)
```

| Format | Example at 40 bits | Length at 40 bits | Good for |
|---|---|---|---|
| `Crockford32` | `BGY81YKJ` | 8 | reading aloud and typing: no I, L, O, U; forgiving input |
| `Base58` | `BQZbwjf` | 7 | links and QR codes: shortest, but case-sensitive |
| `Decimal` | `0396152076914` | 13 | phone keypads |
| `Alphabet` | yours | depends | any other set of characters |

- Codes are fixed-length (zero-padded), so a missing or extra character is
  an error rather than a different number. `fmt.valid?(string)` checks
  without raising.
- `decode` also rejects strings outside the width: not every 7-character
  base58 string is a 40-bit number.
- How forgiving `decode` is depends on the format: Crockford32 ignores case
  and reads O as 0 and I/L as 1, because none of those letters are in its
  alphabet; Base58 is case-sensitive, because `a` and `A` are different
  digits there. The rule is the same everywhere: only characters outside
  the alphabet are remapped or ignored, so a typed variant can never turn
  into a different valid code.
- `group:` and `separator:` only affect output; the separator, spaces and
  hyphens are dropped on input (unless the alphabet uses them as digits).
- `fmt.normalize("tcnh r99b")` returns the canonical form (`"TCNH-R99B"`
  with `group: 4`), or nil when it isn't a code; `fmt.canonical?(string)`
  checks for exactly that form.
- `fmt.decode(string, strict: true)` accepts only the canonical form, for
  input that comes from machines (API clients, webhooks, signed links),
  where any variation means a bug. Lenient is the default, for input from
  people.
- Build your own with `GFC64::Format::Alphabet.new(chars, bits:,
  case_sensitive:, aliases: { "O" => "0" })`.

## Things to know

- **A public id isn't permission.** It hides how many records you have and
  in what order, and it can't be guessed, but anyone who has one can use
  it: a forwarded email or a shared link carries it along. Check that the
  current user may see the record, as you would for a plain id.
- **Never pass a public id to `find`.** Use `find_by_public_id!`, which
  decodes it. `find` doesn't fail safely: ActiveRecord reads the leading
  digits of a string as the id, so `Customer.find("7KQM-R3XH")` returns
  customer 7, and a plain encrypted number at a narrow width (`bits: 24`
  has only about 16.7 million values) can be a real id too. Either way it
  quietly returns someone else's record. Two safety nets:
  - a `prefix:` that starts with a letter (`"INV-"`): `find("INV-7KQM-R3XH")`
    reads as 0 and finds nothing;
  - `has_public_id ..., guard_find: true`: `find` raises `GFC64::UnsafeFind`
    for any String that isn't all digits, so the mistake shows up as an
    error in development and tests instead of a wrong record.

  Neither covers `find_by(id: ...)` or `where(id: ...)`, which read leading
  digits the same way, and the guard can't spot a public id that is itself
  all digits (`has_public_id` without a `format:`).
- **The key is a single point of failure.** Lose it and computed codes can't
  be decoded; leak it and every code, past and future, can be computed and
  listed. Keep it with your other secrets, back it up, and see
  [Keys](#keys). Codes stored with `has_code` keep working either way.
- **Computed codes change if the key, format, prefix or tweak changes,**
  and old links and bookmarks stop working with them. Choose them once, or
  store the codes; see [Computed or stored?](#computed-or-stored).
- **The width caps your ids.** `bits:` (or `radix**length` with FF1) is the
  largest value that can be encoded; beyond it, encoding raises. 40 bits is
  about 1.1 trillion, so pick a width with room to grow.
- **Computed codes aren't searchable in SQL.** There's no `LIKE 'TCNH%'`
  and no sorting by code: look up a whole code (`find_by_public_id`), or
  store the codes if people need to search them.
- **The Feistel cipher hasn't been reviewed;** FF1 is a NIST standard with
  published test vectors. Use FF1 when you need a standard behind the
  numbers ([Which to use](#which-to-use)).

## Disclaimer

This code has not been vetted by a security audit or a professional
cryptographer so may be wrong and/or insecure.

## License

This was written with AI tool assistance. If any code mirrors existing
copyrighted works, it was not my intent, and the copyright remains with the
original works. My contributions are MIT licensed.

## References

Black, John, and Phillip Rogaway. ["Ciphers with Arbitrary Finite Domains."][paper] In Topics in Cryptology — CT-RSA 2002, edited by Bart Preneel, 2271:114–30. Lecture Notes in Computer Science. Berlin, Heidelberg: Springer Berlin Heidelberg, 2002. https://doi.org/10.1007/3-540-45760-7_9.

Hat tip to [this Hacker News comment][hn] that led me to the idea and the paper.

[paper]: https://web.cs.ucdavis.edu/~rogaway/papers/subset.pdf
[crockford]: https://www.crockford.com/base32.html
[tweakable]: https://people.csail.mit.edu/rivest/pubs/LRW02.pdf
[sp800-38g]: https://csrc.nist.gov/pubs/sp/800/38/g/r1/2pd
[hn]: https://news.ycombinator.com/item?id=27016779
