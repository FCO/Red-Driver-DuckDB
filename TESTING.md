# Validation

The complete local Red run passed: 167 files, 2,161 top-level tests, no failures
or timeouts. Nine files had skipped/empty plans. Fifteen native-savepoint subtests
are explicitly skipped; rejection and root-transaction guarantees are tested.
The driver's own suite passed 104 tests in 13 files. See
[the detailed report](RED-SUITE-RESULTS.md).

Use the sibling Red checkout with the companion changes:

```sh
RED_DATABASE=DuckDB RED_TEST_TIMEOUT=600 prove6 -j8 --exec='python3 tools/red-test-exec.py' ../Red/t
RED_DATABASE=DuckDB prove6 -j4 --exec='python3 tools/red-test-exec.py' t
```

For a standalone checkout, install the matching Red source first:

```sh
git clone https://github.com/FCO/Red.git .red
git -C .red checkout 589fc491a8544b0d9c2f0a086431256a71322689
git -C .red apply ../tools/red-companion.patch
zef install --/test .red
zef install --/test --test-depends --deps-only .
prove6 -Ilib t
```

For the full suite against .red, set RED_CHECKOUT=.red and pass .red/t. The
companion patch was applied to a clean local checkout and all 104 driver tests
passed with that source. CI uses the same pinned source and patch.

RED_TEST_RESULTS selects artifacts; RED_TEST_TIMEOUT defaults to 180 seconds.
The launcher preloads DuckDB to avoid Red's t/lib/DB namespace collision, keeps
stdout TAP separate from stderr, and continues after per-file Bail out! output
while retaining the failed exit status and original raw TAP.

Local DuckDB validation ran on macOS ARM64, Rakudo 2026.09-198, DB::DuckDB 1.0.1,
DuckDB 2.0.0. Alien::Libduckdb 1.1.0 required the macOS filename correction in
tools/install-macos-alien.py. Linux/macOS/Windows CI is configured; remote runs
were not observed. See OTHER-DRIVERS-RESULTS.md for full cross-driver inventories;
the latest five capability-test changes passed 61 tests on each other driver.
