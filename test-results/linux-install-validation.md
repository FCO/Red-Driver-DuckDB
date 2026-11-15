# Linux installation validation — 2026-11-15

Environment: Debian Bookworm ARM64, `rakudo-star:2026.09-bookworm`,
Rakudo/MoarVM 2026.09, zef 1.1.4, DuckDB 2.0.0. The base image had no Red,
DB, Alien::Libduckdb or DB::DuckDB installed. Its existing Raku utility packages
included JSON::Fast and App::Prove6.

## Reproduction

The image initially had no C compiler. DB::DuckDB warned that its result bridge
could not compile and chunk reads would fail on this ABI. Installed
`build-essential` before the dependency test reproduction.

`TZ=Europe/Paris zef install --verbose 'DB::DuckDB:ver<1.0.1>:auth<zef:skyter10086>'`
failed with exit status 1. Four test files failed because digest subprocesses
could not find staged `DB`: t/04-varchar-shim.rakutest,
t/10-varchar-join.rakutest, t/12-temporal.rakutest and
t/13-decimal-enum.rakutest. See `linux-install-binding-before.log`.

The separate TIMESTAMPTZ discrepancy in the user's log did not reproduce on
this ARM64 environment. After dependency installation, the full temporal test
also passed all 53 assertions with `TZ=Europe/Paris`; see
`linux-install-temporal-paris.log`. UTC remains in the installation procedure
to give binding tests a consistent environment, not as a verified fix for every
platform's temporal conversion behavior.

## Successful installation

Ran `sh tools/test-install-linux.sh` in a writable copy of the checkout inside
the container. It exited 0. See `linux-install-after.log`.

- Installed and tested DB, Concurrent::Stack and Alien::Libduckdb first.
- Installed DB::DuckDB 1.0.1 with tests enabled and TZ=UTC: PASS.
- Installed Red commit 589fc491a8544b0d9c2f0a086431256a71322689 with the
  project's companion patch. As in CI, this Red installation skipped its suite.
- Installed this driver with its complete test suite enabled: PASS.
- Tool tests: 2 files, 38 assertions, PASS.
- Created a model/table, inserted a row and read it through the installed
  distribution from /tmp, without -Ilib: `Installed driver CRUD OK`.

No tests were disabled for DB::DuckDB or Red::Driver::DuckDB. No upstream
packages or releases were modified. The direct first-time zef installation
still requires the dependency ordering workaround until DB::DuckDB's subprocess
tests propagate zef's staging repository.

The Dockerfile reproduces this installation procedure from the base image;
the script itself was executed in the container for this validation.
Workflow syntax also passed actionlint; the shell script passed sh -n.
