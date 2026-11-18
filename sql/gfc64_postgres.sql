-- gfc64 for Postgres: FF1 (NIST SP 800-38G) in PL/pgSQL on pgcrypto, Crockford
-- base32, and an INSERT trigger that fills a code column from the row's
-- primary key. Produces the same codes as the gem (GFC64::FF1 +
-- GFC64::Format::Crockford32, and has_code's default tweak "table.column").
--
-- Needs only CREATE EXTENSION pgcrypto, so it runs on Amazon RDS / Aurora.
-- Experimental: see "Postgres (database-side codes)" in the README.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---- byte helpers ----------------------------------------------------------

-- Big-endian bytes of a non-negative integer, padded to len bytes.
CREATE OR REPLACE FUNCTION gfc64_num_to_bytes(n numeric, len int) RETURNS bytea
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  out bytea;
BEGIN
  IF len = 0 THEN RETURN ''::bytea; END IF;
  out := decode(repeat('00', len), 'hex');
  FOR i IN REVERSE len - 1..0 LOOP
    out := set_byte(out, i, mod(n, 256)::int);
    n := div(n, 256);
  END LOOP;
  RETURN out;
END $$;

CREATE OR REPLACE FUNCTION gfc64_bytes_to_num(b bytea) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  n numeric := 0;
BEGIN
  FOR i IN 0..length(b) - 1 LOOP
    n := n * 256 + get_byte(b, i);
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION gfc64_xor16(a bytea, b bytea) RETURNS bytea
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  out bytea := a;
BEGIN
  FOR i IN 0..15 LOOP
    out := set_byte(out, i, get_byte(a, i) # get_byte(b, i));
  END LOOP;
  RETURN out;
END $$;

-- One AES block (the key's length picks AES-128/192/256).
CREATE OR REPLACE FUNCTION gfc64_aes(key bytea, block bytea) RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT encrypt(block, key, 'aes-ecb/pad:none')
$$;

-- ---- FF1 -------------------------------------------------------------------

-- Encrypts (or decrypts) x, an integer of n digits in base radix, into another
-- of the same size. Digits are kept as one number per half, so NUM/STR from the
-- standard are just the numbers themselves.
CREATE OR REPLACE FUNCTION gfc64_ff1(key bytea, tweak bytea, radix int, n int, x numeric, decrypting boolean DEFAULT false)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  u int := n / 2;
  v int := n - u;
  t int := length(tweak);
  rv numeric := power(radix::numeric, v);
  a numeric := div(x, rv);
  b numeric := mod(x, rv);
  bb int := 0;        -- b in the standard: bytes for radix^v - 1
  d int;
  p bytea;
  pad bytea;
  q bytea;
  r bytea;
  s bytea;
  y numeric;
  m int;
  rm numeric;
  c numeric;
  tmp numeric;
  i int;
  j int;
BEGIN
  IF radix < 2 OR radix > 65536 THEN RAISE EXCEPTION 'radix must be 2 to 65536'; END IF;
  IF n < 2 OR power(radix::numeric, n) < 1000000 THEN RAISE EXCEPTION 'radix^length must be at least 1,000,000'; END IF;
  IF x < 0 OR x >= power(radix::numeric, n) THEN RAISE EXCEPTION 'value out of range'; END IF;

  tmp := rv - 1;
  WHILE tmp > 0 LOOP bb := bb + 1; tmp := div(tmp, 256); END LOOP;
  d := 4 * ((bb + 3) / 4) + 4;
  p := '\x010201'::bytea || gfc64_num_to_bytes(radix, 3) || '\x0a'::bytea
       || gfc64_num_to_bytes(u % 256, 1) || gfc64_num_to_bytes(n, 4) || gfc64_num_to_bytes(t, 4);
  pad := decode(repeat('00', (((-t - bb - 1) % 16) + 16) % 16), 'hex');

  FOR k IN 0..9 LOOP
    i := CASE WHEN decrypting THEN 9 - k ELSE k END;
    q := tweak || pad || gfc64_num_to_bytes(i, 1)
         || gfc64_num_to_bytes(CASE WHEN decrypting THEN a ELSE b END, bb);
    -- R = PRF(P || Q): CBC-MAC with a zero IV.
    r := decode(repeat('00', 16), 'hex');
    j := 0;
    WHILE j < length(p || q) LOOP
      r := gfc64_aes(key, gfc64_xor16(r, substring(p || q FROM j + 1 FOR 16)));
      j := j + 16;
    END LOOP;
    s := r;
    j := 1;
    WHILE length(s) < d LOOP
      s := s || gfc64_aes(key, gfc64_xor16(r, gfc64_num_to_bytes(j, 16)));
      j := j + 1;
    END LOOP;
    y := gfc64_bytes_to_num(substring(s FROM 1 FOR d));
    m := CASE WHEN i % 2 = 0 THEN u ELSE v END;
    rm := power(radix::numeric, m);
    IF decrypting THEN
      c := mod(mod(b - y, rm) + rm, rm);
      b := a;
      a := c;
    ELSE
      c := mod(a + y, rm);
      a := b;
      b := c;
    END IF;
  END LOOP;
  RETURN a * rv + b;
END $$;

-- ---- Crockford base32 -------------------------------------------------------

CREATE OR REPLACE FUNCTION gfc64_crockford_encode(x numeric, len int, grp int DEFAULT 0) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  alphabet text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  out text := '';
BEGIN
  FOR i IN 1..len LOOP
    out := substr(alphabet, mod(x, 32)::int + 1, 1) || out;
    x := div(x, 32);
  END LOOP;
  IF x > 0 THEN RAISE EXCEPTION 'value too large for % characters', len; END IF;
  IF grp > 0 THEN
    out := array_to_string(ARRAY(SELECT substr(out, g, grp) FROM generate_series(1, len, grp) AS g), '-');
  END IF;
  RETURN out;
END $$;

-- Forgiving: any case, O as 0, I/L as 1, spaces and hyphens ignored.
-- NULL when it isn't a code of exactly len characters.
CREATE OR REPLACE FUNCTION gfc64_crockford_decode(s text, len int) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  alphabet text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  t text := translate(upper(s), 'OIL -', '011');
  n numeric := 0;
  pos int;
BEGIN
  IF length(t) <> len THEN RETURN NULL; END IF;
  FOR i IN 1..len LOOP
    pos := strpos(alphabet, substr(t, i, 1));
    IF pos = 0 THEN RETURN NULL; END IF;
    n := n * 32 + (pos - 1);
  END LOOP;
  RETURN n;
END $$;

-- ---- key + trigger ------------------------------------------------------------

-- Keys live in a table that only the owner (the migration role) can read.
CREATE TABLE IF NOT EXISTS gfc64_keys (name text PRIMARY KEY, key bytea NOT NULL CHECK (length(key) IN (16, 24, 32)));
REVOKE ALL ON gfc64_keys FROM PUBLIC;

-- BEFORE INSERT: column defaults (the id's nextval) are already applied, so
-- NEW.<pk> is the row's real id. Fills <column> when it's NULL.
-- Arguments: column, key name, tweak, prefix, code length, group size, pk column.
-- SECURITY DEFINER so it can read gfc64_keys though the app's role can't.
CREATE OR REPLACE FUNCTION gfc64_assign_code() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  col text := TG_ARGV[0];
  key_name text := TG_ARGV[1];
  tweak text := TG_ARGV[2];
  prefix text := coalesce(TG_ARGV[3], '');
  len int := coalesce(TG_ARGV[4], '8')::int;
  grp int := coalesce(TG_ARGV[5], '4')::int;
  pk text := coalesce(TG_ARGV[6], 'id');
  row_json jsonb := to_jsonb(NEW);
  k bytea;
BEGIN
  IF row_json ->> col IS NOT NULL THEN RETURN NEW; END IF;
  SELECT key INTO STRICT k FROM gfc64_keys WHERE name = key_name;
  NEW := jsonb_populate_record(NEW, jsonb_build_object(col,
           prefix || gfc64_crockford_encode(
             gfc64_ff1(k, convert_to(tweak, 'UTF8'), 32, len, (row_json ->> pk)::numeric), len, grp)));
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION gfc64_assign_code() FROM PUBLIC;

-- Example:
--   INSERT INTO gfc64_keys VALUES ('default', decode('<64 hex chars>', 'hex'));
--   CREATE TRIGGER invoices_number BEFORE INSERT ON invoices FOR EACH ROW
--     EXECUTE FUNCTION gfc64_assign_code('number', 'default', 'invoices.number', 'APP-', '8', '4');
