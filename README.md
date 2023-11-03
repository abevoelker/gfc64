# GFC64

Format-preserving Generalized Feistel Cipher for 64-bit integers. Encrypts 64-bit
integers into... 64-bit integers!

Very useful for if you have sequential 64-bit integer database primary keys that
you want to expose in an app, but you don't want to leak count information
(e.g. `/customers/1`, `/customers/2`, ...), and you don't want to add another
column to store something auxiliary like a UUID.

For example, with this gem, routes like

`/customers/1` can become something like `/customers/4552956331295818987`, and

`/customers/2` can become something like `/customers/3833777695217202560`

## Installation

Add to your `Gemfile`:

```ruby
gem "gfc64"
```

## Usage

```ruby
key = SecureRandom.hex(32) # => "ffb5e3600fc27924f97dc055440403b10ce97160261f2a87eee576584cf942e5"
gfc = GFC64.new(key)
gfc.encrypt(1) # => 4552956331295818987
gfc.decrypt(4552956331295818987) # => 1
gfc.encrypt(2) # => 3833777695217202560
gfc.decrypt(3833777695217202560) # => 2
```

Example use in a Rails app:

```ruby
# app/models/customer.rb

class Customer < ApplicationRecord
  def self.gfc
    @@gfc ||= GFC64.new(ENV['GFC_KEY'])
  end

  def to_param
    self.class.gfc.encrypt(id)
  end

  def self.find_by_param(gfc_id)
    find(gfc.decrypt(gfc_id))
  end
end
```

```ruby
# app/controllers/customers_controller.rb

class CustomersController < ApplicationController
  def show
    @customer = Customer.find_by_param(params[:id])
  end
end

```

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
[hn]: https://news.ycombinator.com/item?id=27016779
