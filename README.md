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
[hn]: https://news.ycombinator.com/item?id=27016779
