-- Create the sqids schema
CREATE SCHEMA IF NOT EXISTS sqids;

-- Create the blocklist table
CREATE TABLE IF NOT EXISTS sqids.blocklist(
  str TEXT PRIMARY KEY
);

-- Create a global temporary table for caching the blocklist
CREATE GLOBAL TEMPORARY TABLE sqids_temp_blocklist (
  str TEXT PRIMARY KEY
) ON COMMIT PRESERVE ROWS;

-- Function to load the blocklist into the temporary table
CREATE OR REPLACE FUNCTION sqids.load_blocklist() RETURNS VOID AS $$
BEGIN
  DELETE FROM sqids_temp_blocklist; -- Clear any existing entries
  INSERT INTO sqids_temp_blocklist (str)
  SELECT LOWER(str) FROM sqids.blocklist;
END;
$$ LANGUAGE plpgsql;

-- Function to check if an ID is blocked
CREATE OR REPLACE FUNCTION sqids.isBlockedId(id TEXT) RETURNS BOOLEAN AS $$
DECLARE
  lowercase_id TEXT := LOWER(id);
  word TEXT;
BEGIN
  FOR word IN SELECT str FROM sqids_temp_blocklist LOOP
    IF LENGTH(word) <= LENGTH(lowercase_id) THEN
      IF LENGTH(lowercase_id) <= 3 OR LENGTH(word) <= 3 THEN
        IF lowercase_id = word THEN
          RETURN TRUE;
        END IF;
      ELSIF POSITION('\d' IN word) > 0 THEN
        IF lowercase_id LIKE word || '%' OR lowercase_id LIKE '%' || word THEN
          RETURN TRUE;
        END IF;
      ELSIF POSITION(word IN lowercase_id) > 0 THEN
        RETURN TRUE;
      END IF;
    END IF;
  END LOOP;

  RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Function to check the alphabet
CREATE OR REPLACE FUNCTION sqids.checkAlphabet(alphabet TEXT) RETURNS BOOLEAN AS $$
DECLARE
  chars CHAR[];
  unique_chars CHAR[];
BEGIN
  IF LENGTH(alphabet) < 3 THEN
    RAISE EXCEPTION 'Alphabet must have at least 3 characters';
  END IF;

  IF octet_length(alphabet) <> length(alphabet) THEN
    RAISE EXCEPTION 'Alphabet must not contain multibyte characters';
  END IF;

  chars := regexp_split_to_array(alphabet, '');
  unique_chars := ARRAY(SELECT DISTINCT unnest(chars));
  IF array_length(chars, 1) <> array_length(unique_chars, 1) THEN
    RAISE EXCEPTION 'Alphabet must not contain duplicate characters';
  END IF;

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Function to shuffle the alphabet
CREATE OR REPLACE FUNCTION sqids.shuffle(alphabet TEXT) RETURNS TEXT AS $$
DECLARE
  chars TEXT[];
  i INT;
  j INT;
  r INT;
  temp TEXT;
BEGIN
  chars := regexp_split_to_array(alphabet, '');
  FOR i IN 1..array_length(chars, 1) LOOP
    j := array_length(chars, 1) - i;
    IF j <= 0 THEN
      EXIT;
    END IF;
    r := (i * j + ascii(chars[i]) + ascii(chars[j])) % array_length(chars, 1);
    temp := chars[i];
    chars[i] := chars[r];
    chars[r] := temp;
  END LOOP;
  RETURN array_to_string(chars, '');
END;
$$ LANGUAGE plpgsql;

-- Function to convert a number to an ID
CREATE OR REPLACE FUNCTION sqids.toId(num BIGINT, alphabet TEXT) RETURNS TEXT AS $$
DECLARE
  id TEXT := '';
  chars TEXT[];
  result BIGINT := num;
BEGIN
  chars := regexp_split_to_array(alphabet, '');
  LOOP
    id := chars[(result % array_length(chars, 1)) + 1] || id;
    result := result / array_length(chars, 1);
    EXIT WHEN result = 0;
  END LOOP;
  RETURN id;
END;
$$ LANGUAGE plpgsql;

-- Function to convert an ID to a number
CREATE OR REPLACE FUNCTION sqids.toNumber(id TEXT, alphabet TEXT) RETURNS BIGINT AS $$
DECLARE
  chars TEXT[];
  result BIGINT := 0;
  i INT;
  char TEXT;
BEGIN
  chars := regexp_split_to_array(alphabet, '');
  FOR i IN 1..LENGTH(id) LOOP
    char := substring(id FROM i FOR 1);
    result := result * array_length(chars, 1) + (array_position(chars, char) - 1);
  END LOOP;
  RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Function to encode numbers into an ID with caching
CREATE OR REPLACE FUNCTION sqids.encode_numbers(numbers BIGINT[], alphabet TEXT, minLength INT, increment INT DEFAULT 0) RETURNS TEXT AS $$
DECLARE
  offset_var INT := 0;
  arr_alphabet TEXT[];
  original_alphabet TEXT := alphabet;
  prefix TEXT;
  ret TEXT := '';
  num BIGINT;
  id TEXT;
  shuffled_alphabet TEXT;
BEGIN
  IF increment > LENGTH(alphabet) THEN
    RAISE EXCEPTION 'Reached max attempts to re-generate the ID';
  END IF;
  IF array_length(numbers, 1) IS NULL THEN
    RETURN '';
  END IF;

  arr_alphabet := regexp_split_to_array(alphabet, '');

  FOR i IN 1..array_length(numbers, 1) LOOP
    offset_var := offset_var + ascii(arr_alphabet[(numbers[i] % array_length(arr_alphabet, 1)) + 1]) + i;
  END LOOP;

  offset_var := (offset_var + increment) % array_length(arr_alphabet, 1);
  arr_alphabet := arr_alphabet[offset_var + 1:] || arr_alphabet[1:offset_var];
  prefix := arr_alphabet[1];

  -- Use subquery to cache shuffled alphabet
  SELECT sqids.shuffle(array_to_string(arr_alphabet, '')) INTO shuffled_alphabet;
  alphabet := reverse(shuffled_alphabet);
  ret := prefix;

  FOR i IN 1..array_length(numbers, 1) LOOP
    num := numbers[i];
    ret := ret || sqids.toId(num, substring(alphabet FROM 2));
    IF i < array_length(numbers, 1) THEN
      ret := ret || substring(alphabet FROM 1 FOR 1);
      SELECT sqids.shuffle(alphabet) INTO alphabet;
    END IF;
  END LOOP;

  id := ret;
  IF LENGTH(id) < minLength THEN
    id := id || substring(alphabet FROM 1 FOR 1);
    WHILE minLength - LENGTH(id) > 0 LOOP
      SELECT sqids.shuffle(alphabet) INTO alphabet;
      id := id || substring(alphabet FROM 1 FOR LEAST(minLength - LENGTH(id), LENGTH(alphabet)));
    END LOOP;
  END IF;

  IF sqids.isBlockedId(id) THEN
    id := sqids.encode_numbers(numbers, original_alphabet, minLength, increment + 1);
  END IF;
  RETURN id;
END;
$$ LANGUAGE plpgsql;

-- Function to encode numbers with a default alphabet
CREATE OR REPLACE FUNCTION sqids.encode(numbers BIGINT[], alphabet TEXT DEFAULT 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', minLength INT DEFAULT 0) RETURNS TEXT AS $$
DECLARE
  id TEXT;
BEGIN
  PERFORM sqids.checkAlphabet(alphabet);
  alphabet := sqids.shuffle(alphabet);

  id := sqids.encode_numbers(numbers, alphabet, minLength);
  RETURN id;
END;
$$ LANGUAGE plpgsql;

-- Overloaded encode function with only numbers and minLength
CREATE OR REPLACE FUNCTION sqids.encode(numbers BIGINT[], minLength INT) RETURNS TEXT AS $$
BEGIN
  RETURN sqids.encode(numbers, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', minLength);
END;
$$ LANGUAGE plpgsql;

-- Function to decode an ID back into an array of numbers
CREATE OR REPLACE FUNCTION sqids.decode(id TEXT, alphabet TEXT DEFAULT 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') RETURNS BIGINT[] AS $$
DECLARE
  ret BIGINT[] := ARRAY[]::BIGINT[];
  prefix TEXT;
  offset_var INT;
  arr_alphabet TEXT[];
  separator TEXT;
  chunks TEXT[];
  slicedId TEXT := substring(id FROM 2);
BEGIN
  IF id = '' THEN
    RETURN ret;
  END IF;

  PERFORM sqids.checkAlphabet(alphabet);
  arr_alphabet := regexp_split_to_array(alphabet, '');
  prefix := substring(id FROM 1 FOR 1);
  offset_var := array_position(arr_alphabet, prefix) - 1;
  arr_alphabet := arr_alphabet[offset_var + 1:] || arr_alphabet[1:offset_var];
  alphabet := array_to_string(arr_alphabet, '');
  alphabet := reverse(alphabet);

  LOOP
    separator := substring(alphabet FROM 1 FOR 1);
    chunks := string_to_array(slicedId, separator);
    IF array_length(chunks, 1) > 0 THEN
      IF chunks[1] = '' THEN
        RETURN ret;
      END IF;
      ret := array_append(ret, sqids.toNumber(chunks[1], substring(alphabet FROM 2)));
      IF array_length(chunks, 1) > 1 THEN
        alphabet := sqids.shuffle(alphabet);
      END IF;
    END IF;
    slicedId := array_to_string(chunks[2:], separator);
  END LOOP;
  RETURN ret;
END;
$$ LANGUAGE plpgsql;

-- Function to insert the default blocklist
CREATE OR REPLACE FUNCTION sqids.defaultBlocklist() RETURNS VOID AS $$
BEGIN
  DELETE FROM sqids.blocklist;
  INSERT INTO sqids.blocklist (str) VALUES
('0rgasm'),('1d10t'),('1d1ot'),('1di0t'),('1diot'),('1eccacu10'),('1eccacu1o'),('1eccacul0'),('1eccaculo'),('1mbec11e'),('1mbec1le'),('1mbeci1e'),('1mbecile'),('a11upat0'),('a11upato'),('a1lupat0'),('a1lupato'),('aand'),('ah01e'),('ah0le'),('aho1e'),('ahole'),('al1upat0'),('al1upato'),('allupat0'),('allupato'),('ana1'),('ana1e'),('anal'),('anale'),('anus'),('arrapat0'),('arrapato'),('arsch'),('arse'),('ass'),('b00b'),('b00be'),('b01ata'),('b0ceta'),('b0iata'),('b0ob'),('b0obe'),('b0sta'),('b1tch'),('b1te'),('b1tte'),('ba1atkar'),('balatkar'),('bastard0'),('bastardo'),('batt0na'),('battona'),('bitch'),('bite'),('bitte'),('bo0b'),('bo0be'),('bo1ata'),('boceta'),('boiata'),('boob'),('boobe'),('bosta'),('bran1age'),('bran1er'),('bran1ette'),('bran1eur'),('bran1euse'),('branlage'),('branler'),('branlette'),('branleur'),('branleuse'),('c0ck'),('c0g110ne'),('c0g11one'),('c0g1i0ne'),('c0g1ione'),('c0gl10ne'),('c0gl1one'),('c0gli0ne'),('c0glione'),('c0na'),('c0nnard'),('c0nnasse'),('c0nne'),('c0u111es'),('c0u11les'),('c0u1l1es'),('c0u1lles'),('c0ui11es'),('c0ui1les'),('c0uil1es'),('c0uilles'),('c11t'),('c11t0'),('c11to'),('c1it'),('c1it0'),('c1ito'),('cabr0n'),('cabra0'),('cabrao'),('cabron'),('caca'),('cacca'),('cacete'),('cagante'),('cagar'),('cagare'),('cagna'),('cara1h0'),('cara1ho'),('caracu10'),('caracu1o'),('caracul0'),('caraculo'),('caralh0'),('caralho'),('cazz0'),('cazz1mma'),('cazzata'),('cazzimma'),('cazzo'),('ch00t1a'),('ch00t1ya'),('ch00tia'),('ch00tiya'),('ch0d'),('ch0ot1a'),('ch0ot1ya'),('ch0otia'),('ch0otiya'),('ch1asse'),('ch1avata'),('ch1er'),('ch1ng0'),('ch1ngadaz0s'),('ch1ngadazos'),('ch1ngader1ta'),('ch1ngaderita'),('ch1ngar'),('ch1ngo'),('ch1ngues'),('ch1nk'),('chatte'),('chiasse'),('chiavata'),('chier'),('ching0'),('chingadaz0s'),('chingadazos'),('chingader1ta'),('chingaderita'),('chingar'),('chingo'),('chingues'),('chink'),('cho0t1a'),('cho0t1ya'),('cho0tia'),('cho0tiya'),('chod'),('choot1a'),('choot1ya'),('chootia'),('chootiya'),('cl1t'),('cl1t0'),('cl1to'),('clit'),('clit0'),('clito'),('cock'),('cog110ne'),('cog11one'),('cog1i0ne'),('cog1ione'),('cogl10ne'),('cogl1one'),('cogli0ne'),('coglione'),('cona'),('connard'),('connasse'),('conne'),('cou111es'),('cou11les'),('cou1l1es'),('cou1lles'),('coui11es'),('coui1les'),('couil1es'),('couilles'),('cracker'),('crap'),('cu10'),('cu1att0ne'),('cu1attone'),('cu1er0'),('cu1ero'),('cu1o'),('cul0'),('culatt0ne'),('culattone'),('culer0'),('culero'),('culo'),('cum'),('cunt'),('d11d0'),('d11do'),('d1ck'),('d1ld0'),('d1ldo'),('damn'),('de1ch'),('deich'),('depp'),('di1d0'),('di1do'),('dick'),('dild0'),('dildo'),('dyke'),('encu1e'),('encule'),('enema'),('enf01re'),('enf0ire'),('enfo1re'),('enfoire'),('estup1d0'),('estup1do'),('estupid0'),('estupido'),('etr0n'),('etron'),('f0da'),('f0der'),('f0ttere'),('f0tters1'),('f0ttersi'),('f0tze'),('f0utre'),('f1ca'),('f1cker'),('f1ga'),('fag'),('fica'),('ficker'),('figa'),('foda'),('foder'),('fottere'),('fotters1'),('fottersi'),('fotze'),('foutre'),('fr0c10'),('fr0c1o'),('fr0ci0'),('fr0cio'),('fr0sc10'),('fr0sc1o'),('fr0sci0'),('fr0scio'),('froc10'),('froc1o'),('froci0'),('frocio'),('frosc10'),('frosc1o'),('frosci0'),('froscio'),('fuck'),('g00'),('g0o'),('g0u1ne'),('g0uine'),('gandu'),('go0'),('goo'),('gou1ne'),('gouine'),('gr0gnasse'),('grognasse'),('haram1'),('harami'),('haramzade'),('hund1n'),('hundin'),('id10t'),('id1ot'),('idi0t'),('idiot'),('imbec11e'),('imbec1le'),('imbeci1e'),('imbecile'),('j1zz'),('jerk'),('jizz'),('k1ke'),('kam1ne'),('kamine'),('kike'),('leccacu10'),('leccacu1o'),('leccacul0'),('leccaculo'),('m1erda'),('m1gn0tta'),('m1gnotta'),('m1nch1a'),('m1nchia'),('m1st'),('mam0n'),('mamahuev0'),('mamahuevo'),('mamon'),('masturbat10n'),('masturbat1on'),('masturbate'),('masturbati0n'),('masturbation'),('merd0s0'),('merd0so'),('merda'),('merde'),('merdos0'),('merdoso'),('mierda'),('mign0tta'),('mignotta'),('minch1a'),('minchia'),('mist'),('musch1'),('muschi'),('n1gger'),('neger'),('negr0'),('negre'),('negro'),('nerch1a'),('nerchia'),('nigger'),('orgasm'),('p00p'),('p011a'),('p01la'),('p0l1a'),('p0lla'),('p0mp1n0'),('p0mp1no'),('p0mpin0'),('p0mpino'),('p0op'),('p0rca'),('p0rn'),('p0rra'),('p0uff1asse'),('p0uffiasse'),('p1p1'),('p1pi'),('p1r1a'),('p1rla'),('p1sc10'),('p1sc1o'),('p1sci0'),('p1scio'),('p1sser'),('pa11e'),('pa1le'),('pal1e'),('palle'),('pane1e1r0'),('pane1e1ro'),('pane1eir0'),('pane1eiro'),('panele1r0'),('panele1ro'),('paneleir0'),('paneleiro'),('patakha'),('pec0r1na'),('pec0rina'),('pecor1na'),('pecorina'),('pen1s'),('pendej0'),('pendejo'),('penis'),('pip1'),('pipi'),('pir1a'),('pirla'),('pisc10'),('pisc1o'),('pisci0'),('piscio'),('pisser'),('po0p'),('po11a'),('po1la'),('pol1a'),('polla'),('pomp1n0'),('pomp1no'),('pompin0'),('pompino'),('poop'),('porca'),('porn'),('porra'),('pouff1asse'),('pouffiasse'),('pr1ck'),('prick'),('pussy'),('put1za'),('puta'),('puta1n'),('putain'),('pute'),('putiza'),('puttana'),('queca'),('r0mp1ba11e'),('r0mp1ba1le'),('r0mp1bal1e'),('r0mp1balle'),('r0mpiba11e'),('r0mpiba1le'),('r0mpibal1e'),('r0mpiballe'),('rand1'),('randi'),('rape'),('recch10ne'),('recch1one'),('recchi0ne'),('recchione'),('retard'),('romp1ba11e'),('romp1ba1le'),('romp1bal1e'),('romp1balle'),('rompiba11e'),('rompiba1le'),('rompibal1e'),('rompiballe'),('ruff1an0'),('ruff1ano'),('ruffian0'),('ruffiano'),('s1ut'),('sa10pe'),('sa1aud'),('sa1ope'),('sacanagem'),('sal0pe'),('salaud'),('salope'),('saugnapf'),('sb0rr0ne'),('sb0rra'),('sb0rrone'),('sbattere'),('sbatters1'),('sbattersi'),('sborr0ne'),('sborra'),('sborrone'),('sc0pare'),('sc0pata'),('sch1ampe'),('sche1se'),('sche1sse'),('scheise'),('scheisse'),('schlampe'),('schwachs1nn1g'),('schwachs1nnig'),('schwachsinn1g'),('schwachsinnig'),('schwanz'),('scopare'),('scopata'),('sexy'),('sh1t'),('shit'),('slut'),('sp0mp1nare'),('sp0mpinare'),('spomp1nare'),('spompinare'),('str0nz0'),('str0nza'),('str0nzo'),('stronz0'),('stronza'),('stronzo'),('stup1d'),('stupid'),('succh1am1'),('succh1ami'),('succhiam1'),('succhiami'),('sucker'),('t0pa'),('tapette'),('test1c1e'),('test1cle'),('testic1e'),('testicle'),('tette'),('topa'),('tr01a'),('tr0ia'),('tr0mbare'),('tr1ng1er'),('tr1ngler'),('tring1er'),('tringler'),('tro1a'),('troia'),('trombare'),('turd'),('twat'),('vaffancu10'),('vaffancu1o'),('vaffancul0'),('vaffanculo'),('vag1na'),('vagina'),('verdammt'),('verga'),('w1chsen'),('wank'),('wichsen'),('x0ch0ta'),('x0chota'),('xana'),('xoch0ta'),('xochota'),('z0cc01a'),('z0cc0la'),('z0cco1a'),('z0ccola'),('z1z1'),('z1zi'),('ziz1'),('zizi'),('zocc01a'),('zocc0la'),('zocco1a'),('zoccola');
END;
$$ LANGUAGE plpgsql;

SELECT sqids.defaultBlocklist();