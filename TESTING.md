# Validation

The complete local Red run passed: 167 files, 2,161 top-level tests, no failures
or timeouts. Nine files had skipped/empty plans. Fifteen native-savepoint subtests
are explicitly skipped; rejection and root-transaction guarantees are tested.
The driver's own suite passed 150 tests in 15 files, and the Raku tools passed
38 tests in two files. See
[the detailed report](RED-SUITE-RESULTS.md).

Use the sibling Red checkout with the companion changes:

```sh
RED_DATABASE=DuckDB RED_TEST_TIMEOUT=600 prove6 -j8 --exec='raku tools/red-test-exec.raku' ../Red/t
RED_DATABASE=DuckDB prove6 -j4 --exec='raku tools/red-test-exec.raku' t
```

For a standalone checkout, install the matching Red source first:

```sh
git clone https://github.com/FCO/Red.git .red
git -C .red checkout 589fc491a8544b0d9c2f0a086431256a71322689
git -C .red apply ../tools/red-companion.patch
zef install --/test .red
zef install --/test --test-depends --deps-only .
prove6 -Ilib t
prove6 -Ilib tools/t
```

For the full suite against .red, set RED_CHECKOUT=.red and pass .red/t. The
companion patch was applied to a clean local checkout and all 150 driver tests
passed with that source. CI uses the same pinned source and patch.

RED_TEST_RESULTS selects artifacts; RED_TEST_TIMEOUT defaults to 180 seconds.
The launcher preloads DuckDB to avoid Red's t/lib/DB namespace collision, keeps
stdout TAP separate from stderr, and continues after per-file Bail out! output
while retaining the failed exit status and original raw TAP.

Local DuckDB validation ran on macOS ARM64, Rakudo 2026.09-198, DB::DuckDB 1.0.1,
DuckDB 2.0.0. Alien::Libduckdb 1.1.0 required the macOS filename correction in
tools/install-native-deps.raku. The fixes have been validated locally on macOS;
the updated Linux/macOS/Windows workflow still needs a new remote run.
The CI follow-up makes quoted-name validation independent of multi candidate
ordering, drains both tool-test output streams concurrently, and builds large
launcher logs without flattening their bytes into an argument list. Windows
extraction uses Git's GNU tar because Windows bsdtar rejects Unicode archive
headers even for excluded files. The Windows change needs validation on a runner.
The combined driver/tool suite passed locally on both Rakudo 2026.09 and
2026.09-198: 17 files, 188 top-level tests, including the 256 KiB stderr case.
See OTHER-DRIVERS-RESULTS.md for full cross-driver inventories;
the latest five capability-test changes passed 61 tests on each other driver.

## Linux installation check

Run a clean installation and the driver/tool tests in Debian ARM64 or AMD64:

```sh
docker build --progress=plain -f tools/Dockerfile.install-check -t red-duckdb-install-check .
```

The image installs a C compiler for DB::DuckDB's result bridge, installs `DB`
and `Alien::Libduckdb` before testing `DB::DuckDB`, and runs the binding tests
with `TZ=UTC`. It then installs the pinned Red source with the companion patch,
installs and tests this driver, runs the tool tests, and checks CRUD through the
installed distribution from outside the checkout. As in CI, the companion Red
installation uses `--/test`; dependency binding and driver tests remain enabled.
The commands are in `tools/test-install-linux.sh`.
