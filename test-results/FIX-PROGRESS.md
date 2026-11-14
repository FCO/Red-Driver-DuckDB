# Fix progress (full-suite goal remains active)

Baseline: RED-SUITE-RESULTS.md (110 pass / 48 fail / 9 zero-test files).
Do not treat the baseline as the current post-fix full-suite result.

Implemented and verified:
- Untyped serial IDs now use BIGINT, matching typed UInt FKs.
- Instant uses numeric POSIX seconds, without double-deflation stringification.
- Date/time extraction uses EXTRACT instead of SQLite STRFTIME text.
- jsonb custom type maps to DuckDB JSON.
- Array columns use JSON storage with typed array inflation; Blob remains binary.
- Product constants use supported HUGEINT / DECIMAL(38,18), rather than width 65.
- The driver accepts btree as an API spelling for the default ART index.

Formerly failing Red files now observed passing: 048, 054, 069, 077, 078, 086.
084 now reaches a remaining unordered-result comparison failure.
090 advances beyond numeric constants but still fails at JsonOperation translation.
Driver type tests and t/08-compatibility-types.rakutest pass.

Use the preloaded launcher to avoid Red t/lib/DB shadowing the installed DB role:
`RED_DATABASE=DuckDB prove6 --exec='python3 /tmp/red-duckdb-fix-exec.py' ...`
It captures per-file logs under /tmp/red-duckdb-fix-results without overwriting
the baseline full-suite archive.

Still required: JSON operations/mutation, projections/concurrency, schema drops,
regex, migration support, remaining test portability assumptions, and full-suite
revalidation. Savepoint semantics cannot be claimed without an implementation;
never make unsupported behavior pass by silently omitting atomicity or FK checks.

## Iteration 1 full-suite revalidation

All 167 Red files executed without an incomplete harness run: 126 passed,
32 failed, 9 skipped/empty plans. Harness reported 1,705 top-level tests.
See red-fix-iteration-1.json and red-fix-iteration-1-logs.tar.gz.

Additional implemented/verified fixes:
- Native DuckDB 2.0 JSON extraction/set/remove with JSON Pointer, including empty
  keys, dynamic keys/indices and negative positions.
- JSON presence, element counts, scalar types, composed updates and recursive
  containment preserving numeric equality and boolean/string distinctions.
- Native BOOLEAN constants, avoiding truthy strings for false projections.
- Optional Red::Schema.drop-schema hook and actual-catalog FK dependency ordering.
- Explicit reversed NULL placement for correct reverse/tail semantics.
- Typed parameter casts preserve rational comparisons in cached query plans.
- Per-connection prepared-query access is protected by a lock.
- Red fixtures now account for isolated DuckDB memory databases and use explicit
  ordering where their assertions require ordering.

Formerly failing additional Red files now pass: 037, 039, 052, 084, 087, 088,
089, 090, 098, 101. SQLite regressions for 052, 098, 101 also pass.
Native probes confirmed that DuckDB 2.0 rejects SAVEPOINT, ALTER ADD FOREIGN KEY,
and SELECT FOR UPDATE. Do not claim these features work or silently emulate
weaker integrity/atomicity. Remaining 32 failures are concentrated in regex,
migration support, native feature limitations and schema-constraint capabilities.

## Iteration 2: regex support

Implemented RE2 lowering for simple trees and a recursive SQL automaton for
lookarounds, conjunctions, Unicode word boundaries, backreferences and scoped
capture registers. Native repeat bounds are chunked without weakening their
accepted language. Rakudo character classes are enumerated to static Unicode
ranges; no row-level Raku callbacks are used. Whole-match text uses RE2 extraction
or fixed-width SQL spans; variable-width advanced spans remain explicit errors.
Scalar capture text remains PostgreSQL-only as in Red's existing contract.

All targeted regex files now pass, including 109, 111, 112, 113, 114, 115, 116,
117, 118, 119, 121, 122 and 123. Tests 114/116 were updated to execute the newly
supported paths instead of assuming that only MySQL could support them. Tests
122/123 now exercise DuckDB whole-text methods/counts. The 100 constraints test
now distinguishes explicitly selected driver-only partial indexes from unguarded
unsupported partial indexes, which remain rejected. Own suite: 81 tests pass.
SQLite regressions (100, 114, 116, 122, 123): 57 tests pass.

Reproducible launcher: tools/red-test-exec.py. It resolves sibling checkouts,
preloads the driver, enforces per-file timeouts and records raw stdout TAP and
stderr separately. This fixes false parse failures caused by Rakudo warnings
being merged into nested TAP. Original per-file Bail out! output is preserved;
its harness form is a diagnostic so other files still run.

Full iteration-2 run: 167 files, 136 pass / 22 fail / 9 skipped or empty,
1,852 top-level tests. Snapshot: red-fix-iteration-2.json and its log archive.
After that snapshot, the 114/116 test capability assumptions were corrected and
both were independently verified passing. A new complete run is still required.

Known remaining failures: native limitations (017 cyclic schema, 081 row locks,
096/097/099 savepoints), and 15 migration files: 128, 130, 131, 132, 133, 136,
138, 147, 148, 149, 154, 156, 157, 158, 161. Do not hide unsupported semantics.

Next migration entry points: Manager !driver/!dialect allowlists, Bundle driver
validation, Environment temporary-database provisioning, Planner sequence DDL,
and Manager migration locking/transaction execution. The latest native probes
confirmed DuckDB 2.0 rejects SAVEPOINT, ALTER ADD FOREIGN KEY, and FOR UPDATE.

## Latest complete verification

All 167 files rerun: 138 passed, 20 failed, 9 skipped/empty; 1,852 top-level
tests, 107 seconds, no timeouts. Own suite: 11 files / 81 tests passed.
No implementation or test changes during this audit. Current artifacts:
red-full-current.json, red-full-current.log, red-full-current-logs.tar.gz.
The 20 known failures above remain unresolved.

## Migration planner implementation

Red::Migration::Planner now generates DuckDB CREATE SEQUENCE followed by a
BIGINT automatic primary key with a quoted nextval reference, and removes owned
sequences after table removal in the destructive reverse diff. Other dialects
retain their existing branches. New t/12-migration-planner.rakutest passes all
8 assertions against native DuckDB: SQL execution, IDs, rollback, and recreation,
including a mixed-case table name. Manager/Bundle allowlists remain unchanged
until execution locking and transactions are implemented.

Native probe /tmp/duck-migration-lock-probe.raku verified that a dedicated
connection holding an uncommitted UPDATE to a lock row rejects another writer,
permits independent migration DDL/data transactions on the primary connection,
and releases the lease on rollback. This supplies the next implementation path;
it is not yet wired into Manager. Full suite still has 20 known failing files.

## Migration executor integration

Implemented driver acquire/release-migration-lock using a dedicated native
connection with an uncommitted UPDATE of red_migration_lock; main connection
retains per-version transactional DDL/data/history. Manager and Bundle accept
DuckDB; status opens a read-only snapshot without creating bookkeeping tables.
Sync and managed-table removal use DuckDB transactions. Reset removes generated
sequences. Temporary environments use .duckdb files and close native handles;
Manager.test releases the parent handle for a child process and reopens afterward.
Default Str now uses canonical VARCHAR, matching DuckDB catalog introspection.
Lock table is reserved and excluded from migration schema verification.

Verified on current code: Red 128/130/131/132/136 pass, 46 tests. Native physical
connection exclusion tested with a shared database handle (independent :memory:
instances are isolated). Red 149 now provides DuckDB's explicit BIGINT conversion
SQL and passes all 6 assertions. Own suite: 12 files, 89 tests pass. SQLite
128/130/131/132/136 regressions: 46 tests pass. Both worktree diff checks pass.

Earlier integration pass additionally verified 138,148,156,157,158. Remaining
migration failures: 133/147 (DuckDB SET NOT NULL after updates in same transaction
rejects outstanding updates; do not split atomic migration commits), 154 (fixture
runs CLI child while parent holds file), 161 (handwritten INTEGER FK to BIGINT
serial, then native cycle fixture unsupported). All ten integration artifacts
are retained in migration-integration-logs.tar.gz. No timeout in that run.
A new complete suite is required; the last full audit predates these changes.
Nonmigration native limitations (017,081,096,097,099) remain unresolved.

## Transactional tightening, reset and installed-chain validation

DuckDB migration-set-not-null reconstructs the table within the existing migration
transaction, preserving catalog columns/defaults, PK/UNIQUE/CHECK/FK constraints,
indexes and table/column comments. Generated-column reconstruction is rejected.
The helper requires an explicit transaction. Query-based transaction control is
now tracked as DB::DuckDB only tracks its execute() path; begin/commit/rollback
and reopen honor that state. Reopen provides a fresh connection after an explicit
file handoff to a child process.

Red Manager calls this helper only for the exact generated SET NOT NULL statement;
other SQL retains normal execution. No commit is inserted between data and DDL.
Red 133 and147 pass (29 tests). New t13 verifies successful tightening, rollback
of data/schema, preserved defaults/constraints/index/comments and rejection of
reconstruction outside a transaction. Own suite plus Red133/147/161: 16 files,
164 tests pass. SQLite133/147/161: 50 tests pass.

Red161 uses BIGINT for its handwritten DuckDB FK and explicitly tests native
rejection of ALTER ADD FK cycles; other reset coverage still runs. Red154 hands
the DuckDB file from parent to CLI and reopens afterward. Its complete installed
five-level test independently passed 95 assertions in 146.71 seconds. The latest
complete-suite run is still being observed; do not infer its result from subsets.

Full post-migrations run completed: 167 files, 153 pass / 5 fail / 9 skipped or
empty, 2,113 top-level tests, 238 seconds, no timeouts. All 15 previously failing
migration files passed. Snapshot: red-post-migrations-full.json and log archive.
Next: native capability-aware tests for017/081/096/097/099 without losing ordinary
transaction or mock-guard coverage. Native unsupported semantics remain explicit.

## Other-driver regression audit (in progress)

User asked whether other drivers still pass. Full native default SQLite suite
passed: 167 files, 2,313 tests, 531 seconds. Log:
/tmp/red-regression-sqlite-default-full.log. Docker attempts using old images
lacked Configuration and are invalid migration evidence. Explicit RED_DATABASE=
SQLite also trips an unchanged events fixture; default-mode t028 passes.

Complete-dependency Docker run PostgreSQL: all but t154 passed; t154 hit its
300s limit after 64 successful assertions. Own Pg suite: 3 files /26 tests PASS.
/tmp/red-regression-Pg-complete contains raw per-file outputs. An isolated t154
rerun with 600s is live via session84949 in container
red-duck-regression-pg-test-long; outputs /tmp/red-regression-Pg-long.

MySQL audit exposed pre-existing metadata omissions. Reproduced t128 failure on
unmodified Red HEAD (/tmp/red-regression-MySQL-complete/baseline-128.log).
Sibling Red-Driver-MySQL now preserves auto-increment from information_schema
EXTRA and parsed AUTO_INCREMENT, plus ordered UNIQUE groups (inline and table
constraints). Tests03/04 expanded; Changes updated. After auto fix the complete
run had only t131 failing due missing UNIQUE groups; own11 files/110 tests PASS.
The final groups fix independently passed Red131's12 checks and reader unit
tests. Final complete run live via session33245, container
red-duck-regression-mysql-test-final, outputs /tmp/red-regression-MySQL-final.
Snapshot /tmp/red-other-drivers-final-checkout.tar; latest generic launcher
/tmp/red-other-driver-exec.py uses600s timeout, separate stdout/stderr, per-file
DBs via existing driver launchers. Both final sessions must be observed to
completion before claiming cross-driver regressions are green.

Created disposable services red-duck-regression-pg, red-duck-regression-mysql,
red-duck-regression-mysql-final on red-duck-regression-net. Remove only these
when all runs finish. Temporary cache image red-duck-regression-mysql-cache:local
can then be removed. Original production/workshop/regex containers are unrelated.
Main DuckDB goal still has five known native capability failures; no change to
those tests during this cross-driver audit. No commits or pushes.

Other-driver audit completed: SQLite167 files/2313 tests PASS; PostgreSQL all167
files/2161 tests PASS after isolated t154 timeout rerun, own3files/26tests PASS;
MySQL final single full run167files/2190tests PASS, own11files/114tests PASS.
MySQL schema reader fixes preserve AUTO_INCREMENT and UNIQUE groups; patch and
all evidence in OTHER-DRIVERS-RESULTS.md and test-results/other-drivers. Latest
MySQL code diff checks pass. Main DuckDB five native failures remain unresolved.

## Final capability-aware verification

All167 Red files now execute with PASS: 158 passed /0 failed /9 skipped or empty,
2,161 top-level tests, 242 seconds, no timeout. Native capability distinctions
are explicit:15 savepoint scenarios skipped (7 in096,6 in097,2 in099), while
root transaction, async and mock guard tests execute, plus new rejection/rollback
and no-write checks. Row locks reject with typed Unsupported before SQL. Pretty
printing exercises persisted bidirectional navigation without requiring SQL FK
cycles; unsupported cycle rejection remains independently asserted.

Own suite104 tests/13files PASS. Five modified capability files passed61 tests
on each of SQLite, PostgreSQL and MySQL with positive savepoint cases enabled.
Raw logs/summaries are linked in RED-SUITE-RESULTS.md. Published unsupported
features were not emulated with weaker semantics. Earlier snapshots are historical.

Packaged tools/red-companion.patch reproduces26 changed Red files exactly from
remote-verified commit589fc491a8544b0d9c2f0a086431256a71322689. Clean application,
reverse-check and byte-for-byte comparison passed. Own104 tests passed again
against that reconstructed checkout. CI checks out/apply/installs that Red before
the driver; YAML parsed. Remote cross-platform CI was not run or claimed.
Companion Red and MySQL fixes remain uncommitted in their sibling checkouts.
The generated DuckDB.sqlite3 fixture artifact was removed; disposable regression
services and networks were stopped/removed. No commits, pushes or publication.
