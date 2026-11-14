# Full Red suite with DuckDB — final local validation

**Result: PASS for the declared driver capabilities.**

All **167** Red files executed: **158 passed, zero failed, 9 skipped or had empty
plans**. The harness reported **2,161 top-level tests** in 242 seconds. No timeout
occurred. The driver's own suite passed **104 tests in 13 files**.

This is not a claim that DuckDB supports every feature available in Red. Inside
three transaction files, **15 native-savepoint scenarios are explicitly skipped**
because the driver reports supports-savepoints=False. Those features remain
unsupported. The test matrix now distinguishes supported execution from explicit
rejection, rather than failing while setting up an unavailable native feature.

## Resolution of the last five files

- 017: tests cyclic-schema rejection before DDL, then pretty-prints persisted
  parent/child objects with bidirectional navigation in an acyclic SQL schema.
  Other drivers retain the original cyclic fixture.
- 081: DuckDB rejects row locking with X::Red::Compiler::Unsupported before
  executing SQL. Ordinary queries and data remain usable. Other backends retain
  the existing positive locking assertions.
- 096: identifier-quoting checks still execute. Seven native-savepoint scenarios
  are skipped. New negative cases verify all three savepoint operations, nested
  body rejection, a usable outer transaction, and root rollback on escaping error.
- 097: six native child-scope scenarios are skipped. Root transactions, async
  guards, cleanup, reference-counting and mock-driver savepoint coverage execute.
  Mixed subtests retain their mock or root-transaction portions.
- 099: two native nested cases are skipped. Other relationship creation tests
  execute; new negative checks prove rejected nesting creates no related row,
  preserves in-memory and persisted FKs, and leaves the outer transaction usable.

All previously failing migration files execute successfully, including atomic
NULL filling plus NOT NULL enforcement and the installed five-level fixture.

## Regression and reproducibility

The five changed capability files also passed on SQLite, PostgreSQL and MySQL:
5 files /61 tests in each, with their original positive savepoint paths enabled.
Earlier complete cross-driver inventories and MySQL metadata fixes are documented
in [OTHER-DRIVERS-RESULTS.md](OTHER-DRIVERS-RESULTS.md).

Validation used macOS ARM64, Rakudo 2026.09-198, DB::DuckDB 1.0.1, DuckDB 2.0.0,
and Red commit 589fc491a8544b0d9c2f0a086431256a71322689 with companion changes.
The full run used eight workers and a 600-second per-file timeout. Some Red files
exercise backend-independent logic or explicitly construct other backends, so
passing every file does not mean every assertion queried DuckDB.

[tools/red-companion.patch](tools/red-companion.patch) reproduces all 26 changed
Red files exactly from that clean commit. The patch applies cleanly; the driver's
104 tests also passed using this reconstructed source. CI now checks out that
commit and applies the patch before installing Red. The workflow parses as YAML;
remote Linux/Windows/macOS CI results have not been observed in this session.

## Evidence

- [Full harness](test-results/red-duckdb-capabilities-full.log)
- [Per-file inventory and skip counts](test-results/red-capabilities-full.json)
- [Raw TAP, stderr and commands](test-results/red-capabilities-full-logs.tar.gz)
- [Own driver tests](test-results/red-duckdb-capabilities-own.log)
- [Own tests with reconstructed Red](test-results/red-duckdb-companion-own.log)
- [SQLite capability regressions](test-results/red-duckdb-capabilities-sqlite.log)
- [PostgreSQL capability regressions](test-results/capability-pg-regression.log)
- [MySQL capability regressions](test-results/capability-mysql-regression.log)

Historical failed snapshots remain in test-results for comparison.
