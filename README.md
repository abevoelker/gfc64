# GFC64

Encrypt 64-bit integers into other 64-bit integers without collisions.

Useful for hiding database auto-incrementing primary keys without needing
to store additional data (like a UUID field).

For example, say you have a web app where routes are stored like `/customers/:id`
so that you have exposed URL paths like this:

`/customers/1`

`/customers/2`

With this gem, you can (at view-time) encrypt the above IDs into different IDs
so that you get these paths instead, without storing any additional data:

`/customers/4552956331295818987` (the backend decrypts this into `/customers/1`)

`/customers/3833777695217202560` (the backend decrypts this into `/customers/2`)

All while keeping your auto-incrementing, sequential IDs in your database and
getting all the benefits of a standard database index.

The encryption is achieved by implementing a format-preserving
[Generalized Feistel Cipher][paper].

## Installation

Add to your `Gemfile`:

```ruby
gem "gfc64"
```

## General Usage

```ruby
key = SecureRandom.hex(32) # => "ffb5e3600fc27924f97dc055440403b10ce97160261f2a87eee576584cf942e5"
gfc = GFC64.new(key)
gfc.encrypt(1) # => 4552956331295818987
gfc.decrypt(4552956331295818987) # => 1
gfc.encrypt(2) # => 3833777695217202560
gfc.decrypt(3833777695217202560) # => 2
```

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

| Format | `encrypt(1)` with the key above | Length at 40 bits | Good for |
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
- `group:` and `separator:` only affect output; the separator, spaces and
  hyphens are dropped on input.
- Build your own with `GFC64::Format::Alphabet.new(chars, bits:,
  case_sensitive:, aliases: { "O" => "0" })`.

## Rails Usage

For Rails, there's an ActiveRecord mixin which adds `#gfc_id` and
`#to_param` methods and a `::find_gfc` class method. By setting `#to_param`,
resource path helpers like `customer_path(@customer)` automatically use the
GFC encrypted ID.

Example usage:

```ruby
# app/models/customer.rb

class Customer < ApplicationRecord
  include GFC64::ActiveRecord[GFC64.new(ENV['GFC_KEY'])]
  # or the argument can be a proc/lambda if you need late binding:
  # include GFC64::ActiveRecord[-> { GFC64.new(ENV['GFC_KEY']) }]
end
```

For retrieval, use `::find_gfc`:

```ruby
# app/controllers/customers_controller.rb

class CustomersController < ApplicationController
  def show
    @customer = Customer.find_gfc(params[:id])
  end
end
```

## Potential drawbacks

Ruby's dynamic typing means we're just passing bare Integers around, so it's
possible to make a mistake where you write something like `Model.find(gfc_id)`
and return a completely unexpected record because you forgot to decrypt the ID.

With a type system it would be trivial to prevent these errors. However, the
space of 64-bit integers is very large, and encrypted IDs tend to occupy numbers
much higher than most web apps will ever reach, so more than likely this sort of
error would be discovered quickly as queries fail to find anything.

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
[hn]: https://news.ycombinator.com/item?id=27016779
