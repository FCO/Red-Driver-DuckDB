[![Actions Status](https://github.com/FCO/Red-Driver-DuckDB/actions/workflows/test.yml/badge.svg)](https://github.com/FCO/Red-Driver-DuckDB/actions)

Red::Driver::DuckDB
===================

DuckDB backend for the Raku [Red ORM](https://github.com/FCO/Red), built on [DB::DuckDB](https://raku.land/zef:skyter10086/DB::DuckDB).

Installation
------------

Requires Raku 6.d and DB::DuckDB 1.0.1, whose native binding targets DuckDB 2.x. Alien::Libduckdb installs the native library automatically. On macOS, first run `raku tools/install-native-deps.raku macos`: Alien 1.1.0 downloads the correct archive but omits `.dylib` from its library lookup. This helper installs that exact release with only the missing macOS filenames corrected. On Windows, run `raku tools/install-native-deps.raku windows` before installing the driver dependencies. It extracts the runtime files of DB::DuckDB 1.0.1 to bypass the zef tar extraction failure on Unicode documentation filenames, then installs that unchanged runtime. Both helpers use the native `curl` and `tar` utilities.

On Linux, a C compiler is required to build DB::DuckDB's result bridge, even when Alien downloads a prebuilt DuckDB library. On Debian/Ubuntu, install it with `sudo apt-get install build-essential`.

The published DB::DuckDB 1.0.1 tests spawn Raku processes that cannot see zef's staged dependencies. On Linux, install those dependencies first, then run the binding tests in UTC to avoid the reported TIMESTAMPTZ timezone mismatch:

```sh
zef install DB Alien::Libduckdb File::Temp
TZ=UTC zef install 'DB::DuckDB:ver<1.0.1>:auth<zef:skyter10086>'
zef install Red::Driver::DuckDB
```

This makes staged dependencies visible to the subprocess tests without skipping tests. UTC also gives the temporal tests a consistent installation environment. The driver still requires the Red companion changes described below.

```sh
git clone https://github.com/FCO/Red.git .red
git -C .red checkout 589fc491a8544b0d9c2f0a086431256a71322689
git -C .red apply ../tools/red-companion.patch
zef install --/test .red
zef install --/test --deps-only .
zef install .
```

The companion changes are currently required; installing an arbitrary published Red release does not reproduce the schema/migration behavior tested here. See [TESTING.md](TESTING.md) for full validation commands.

Usage
-----

```raku
use Red;
my $*RED-DB = database 'DuckDB', :database('example.duckdb');

model Reading {
    has Int $.id is serial;
    has Str $.sensor is column;
    has Rat $.value is column;
}

schema(Reading).create;
Reading.^create(:sensor<temperature>, :value(21.5));
say Reading.^all.grep(*.value > 20).map(*.sensor);
```

Omit `:database` for an isolated in-memory database. An existing `DB::DuckDB` object can be supplied as `:dbh`; the driver retains it and opens a connection on that database. Statements and transaction wrappers retain that connection. `.close` closes the driver connection; it leaves the shared `dbh` owned by the caller. For Red's environment-based test configuration use `RED_DATABASE='DuckDB'` or `RED_DATABASE='DuckDB database=/path/to/data.duckdb'`.

Supported: model CRUD with `RETURNING`, sequence-backed serial IDs, relationships, foreign keys, joins, grouping, ordering, pagination, primary and unique constraints, ordinary ART indexes, schema catalog inspection, and begin/commit/rollback. Types include integers, booleans, strings, floating point, `DECIMAL(38,18)` for `Rat`, dates, UTC timestamps, blobs, UUID and JSON values. Decimals bind as text to avoid DB::DuckDB's conversion of rational parameters to double precision. Values outside the declared decimal range/scale remain subject to DuckDB's rules.

Reading files as models
----------------------

The readers infer the columns with DuckDB and return a Red model type, without
writing a model declaration or calling `.^create-table`:

```raku
use Red;
use Red::Driver::DuckDB;

my $db = Red::Driver::DuckDB.new;
my \Pessoa = $db.read-csv('pessoa.csv', :header, :delim<;>);
.say for Pessoa.^all.grep(*.idade >= 18);
```

Available readers are `read-csv`, `read-json`, `read-parquet`, `read-text`,
`read-blob`, and `read-xlsx`. Options retain DuckDB's names, for example
`:union_by_name`, `:all_varchar`, or `:sheet<Vendas>`. Paths, supported file lists,
and glob patterns are passed to DuckDB. Text and blob readers produce one row
per file, including its content and metadata. Excel requires the `excel`
extension, installed and loaded on use.

By default, each call creates a separate temporary **read-only view**. Filters,
ordering and aggregates run in DuckDB against the source. The model retains its
driver, so queries work outside the original `$*RED-DB` scope. Call `$db.close`
when finished; subsequent queries fail because the connection is closed.

Use `:materialize` to import a snapshot into a temporary writable table:

```raku
my \PersonCopy = $db.read-csv('pessoa.csv', :header, :materialize);
my $person = PersonCopy.^create(:nome<Carla>, :idade(25));
$person.idade = 26;
$person.^save;
$person.^delete;
```

The copy receives its own serial primary key named `red_row_id` (with a suffix
if that name already occurs). Its CRUD operations never modify the original
file. Both views and copies last for the connection's lifetime; importing into
a file-backed DuckDB does not make these temporary objects persistent.

Column names are normalized to Raku attribute names, with numeric suffixes for
collisions. `Pessoa.^source-columns` returns the attribute-to-original-column
mapping. Schemas are inferred when the model is created; call the reader again
after changing a source's schema. Supported scalar types use the driver's Raku
types. Lists and arrays become arrays, while structs and maps with text keys
become hashes, through JSON conversion. SQL NULL becomes an undefined value.
Composite columns are readable but their modification and batch updates of
models containing them are rejected; unsupported
types report the offending column and type rather than silently becoming text.

S3 and HTTPS
------------

Configure a temporary S3 secret on the same driver before reading private data:

```raku
$db.configure-s3(:region<eu-west-1>); # AWS credential chain
my \Sale = $db.read-parquet('s3://my-bucket/sales/*.parquet');
.say for Sale.^all.grep(*.total > 100);

my \RemotePerson = $db.read-csv('https://example.org/people.csv', :header);
```

`configure-s3` returns the driver. The default `credential_chain` provider uses
AWS profiles, environment credentials or IAM roles; select a profile with
`:profile<work>`. To supply keys explicitly, use `:provider<config>`, `:key-id`,
`:secret`, and optional `:session-token`. Other options are `:region`, `:scope`,
`:endpoint`, `:url-style<path>` or `:url-style<vhost>`, `:use-ssl`/`:!use-ssl`,
and a secret `:name` (default `red_s3`). An endpoint is a host with optional port,
without the URL scheme. This also supports compatible services such as MinIO.
The helper loads `httpfs` and, for credential-chain authentication, `aws`.
Secrets are temporary and the helper suppresses credential-bearing SQL logs.

The available formats and transports depend on DuckDB's installed extensions.
Their first installation requires access to the DuckDB extension repository.
Remote views query the source on demand; `:materialize` makes a local snapshot.
There is no upload/write-back API in these readers.

Limits
------

DuckDB does not support savepoints; `.supports-savepoints` returns `False`. Nested Red transactions are rejected rather than emulated. Cyclic foreign-key schemas are rejected before schema creation; foreign keys are declared inline and dependencies created first. Schema removal uses the optional `Red::Schema` backend hook added in the sibling Red checkout to drop child tables before their referenced parents. Serial sequences remain after dropping tables, so recreating a table does not reset its counter.

Row-level locks are explicitly rejected before SQL execution. Partial indexes, PostgreSQL operator classes and exclusion constraints are not supported. Structured regex predicates use native RE2 or a recursive SQL automaton, including lookarounds and backreferences. Whole-match text is supported for native patterns and fixed-width automaton spans; scalar capture text and unsupported Match-boundary reads remain explicit errors. JSON supports path reads, updates, deletion, presence, element counts and recursive containment, including dynamic keys/indices. Backend-specific SQL functions are available through `.execute`. Migration support requires the companion changes in the sibling Red checkout: sequence planning, transactional execution and a separate connection holding a database-scoped migration lock. NOT NULL tightening uses transactional table reconstruction; defaults, constraints, indexes and comments are preserved. Tables with generated columns require explicit SQL, and native dependencies can prevent reconstruction. Temporary database tests transfer file ownership to child processes because DuckDB permits one writer process. Native database errors retain their cause; uniqueness and existing-table errors map to Red's corresponding exceptions.

Tests
-----

The current complete Red run passes for declared capabilities: 167 files, 2,161 top-level tests, with 15 native-savepoint scenarios explicitly skipped. The driver suite passes 150 tests, with another 36 tests covering the Raku tools. See [TESTING.md](TESTING.md) for the matching Red checkout and companion patch needed to reproduce these results. CI installs that patched source; the changes are not yet published as a Red release.

```sh
prove6 -Ilib t
# With a sibling Red checkout:
RED_DATABASE=DuckDB prove6 -I../Red/lib -Ilib t ../Red/t/035-create.rakutest
```

CI runs the driver tests on Linux, macOS and Windows. Local validation is on macOS; CI outcomes on the other platforms must be checked separately.

Backend choice
--------------

DB::DuckDB offers the connection/statement/result interfaces needed by Red and manages native library installation. Duckie is also a general DuckDB binding, while Duck::CSV is a CSV reader rather than an ORM backend. The driver uses only DB::DuckDB; CSV, Parquet, Arrow and appender-specific APIs are outside its scope.

Artistic-2.0. Copyright 2026 Fernando Correa de Oliveira.

