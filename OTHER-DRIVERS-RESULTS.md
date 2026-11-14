# Other-driver regression verification

All three backends passed the Red test inventory with the current companion
changes. Each inventory contains all 167 Red files, including backend-specific
skips and empty plans. Counts are top-level TAP assertions, not nested assertions.

| Backend | Red files | Red tests | Own driver tests | Result |
|---|---:|---:|---:|---|
| SQLite | 167 | 2,313 | part of Red | PASS |
| PostgreSQL 15 | 167 | 2,161 | 26 in 3 files | PASS |
| MySQL 8.4 | 167 | 2,190 | 114 in 11 files | PASS |

SQLite ran natively on macOS with RED_DATABASE unset (the normal default).
PostgreSQL and MySQL ran in isolated Linux ARM64 containers with Rakudo 2026.09,
one disposable database per file, using the local driver checkouts. The Red
checkout is `589fc491a8544b0d9c2f0a086431256a71322689` with the existing
uncommitted DuckDB companion changes. PostgreSQL driver HEAD:
`0131fe7e0295a06303b78041387443159e368e25`. MySQL driver HEAD:
`abe3a0ee01f62dc7f4da371c74a4a3bdddf77ddb`, plus the fixes described below.

## Fix found during the audit

MySQL schema introspection omitted AUTO_INCREMENT and ordered UNIQUE groups.
The former failure was reproduced using unmodified Red HEAD; it was not caused
by the DuckDB companion changes. Both omissions are fixed in the sibling MySQL
schema reader, with parser and live-catalog regressions. Natural primary keys
remain distinguished from automatic IDs; composite unique groups remain ordered.
See [the MySQL patch](test-results/other-drivers/mysql-fixes.patch).

The final MySQL run is a single complete successful harness run. Its own suite
also passed after the fix. These fixes did not add skips to driver tests.

## Execution qualifications

The first PostgreSQL full run exceeded a 300-second timeout in the installed
five-level fixture after 64 successful checks. The other 166 files passed.
The same fixture passed all 95 checks when repeated alone with a 600-second
limit (318.98 seconds). PostgreSQL results combine that verified rerun with the
unchanged 166-file results. The source used for those Red/Pg files was identical.

Early Docker images lacked the new Configuration dependency; those failed
setup attempts are excluded from the final results. Explicitly setting
RED_DATABASE=SQLite trips an unchanged events-fixture assumption; both its
repeat in default mode and the complete default SQLite suite passed.

Passing these suites is evidence for the current checkouts and tested versions,
not every database version or platform. A later capability-aware DuckDB run passed with explicit native-savepoint
skips; see RED-SUITE-RESULTS.md. The five subsequently adapted capability files
also passed 61 tests on each other driver, retaining their positive paths. No commits or releases were made.

## Evidence

- [Result inventory](test-results/other-drivers/summary.json)
- [SQLite complete harness](test-results/other-drivers/sqlite-harness.log)
- [PostgreSQL file inventory](test-results/other-drivers/pg-results.json)
- [PostgreSQL original harness](test-results/other-drivers/pg-original-harness.log)
- [PostgreSQL five-level rerun](test-results/other-drivers/pg-five-levels-rerun.log)
- [PostgreSQL driver harness](test-results/other-drivers/pg-driver-harness.log)
- [MySQL complete harness](test-results/other-drivers/mysql-red-harness.log)
- [MySQL driver harness](test-results/other-drivers/mysql-driver-harness.log)
- [MySQL file inventory](test-results/other-drivers/mysql-results.json)
- [Unmodified Red reproducer](test-results/other-drivers/mysql-baseline-128.log)

Raw per-file TAP, stderr, commands and timings are retained in the PostgreSQL and
MySQL log archives under test-results/other-drivers. Launchers and source
snapshot hashes are retained there and in other-drivers-validation-manifest.json.
