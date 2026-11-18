# Changelog

## 1.0.0

### Upgrading from 0.1.0

- 64-bit values are unchanged: the same key gives the same numbers.
- **Example and non-random keys now raise `ArgumentError`:** the README's
  old example key, NIST's FF1 test keys, and keys of one or two repeated
  bytes. Generate a key with `GFC64.generate_key`, or pass
  `insecure_test_key: true` in tests.
- `GFC64::ActiveRecord` (`include GFC64::ActiveRecord[gfc]`) still works but
  is deprecated in favor of `has_public_id`; `has_public_id tweak: false`
  with the same key gives the same numbers. `find_gfc` now accepts the
  String from `params` and raises `ActiveRecord::RecordNotFound` for bad
  values instead of `ArgumentError`.

### Added

- `bits:`: encrypt integers of any even width from 16 to 64 (10 rounds by
  default below 64 bits).
- `tweak:`: independent mappings under one key (e.g. per model).
- `GFC64::FF1`: NIST SP 800-38G FF1 for AES-128/192/256, radix 2 to
  65,536, with tweaks; passes all nine NIST FF1 sample vectors.
- `GFC64::Format`: fixed-length codes in Crockford base32, base58, decimal
  or any alphabet, with forgiving decoding where the alphabet allows it,
  `normalize`, `canonical?` and `decode(strict: true)`.
- `GFC64.generate_key` and `GFC64::FF1.generate_key`.
- Rails helpers, on every model:
  - `has_public_id`: computed public ids (`to_param`,
    `find_by_public_id!`), per-model tweaks, prefixes, strict lookups,
    `canonical_public_id`, and opt-in `guard_find`.
  - `has_code`: a code made from the record's primary key (or a separate
    sequence) and stored in a column, with `find_by_code!`,
    `normalize_code` and `code_sequence_value`.
  - One app-wide key from `GFC64.configure` or `GFC64_KEY`, read on first
    use.

## 0.1.0

- `GFC64.new(key)`: a Feistel cipher over 64-bit integers, and the
  `GFC64::ActiveRecord` mixin.
