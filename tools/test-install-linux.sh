#!/bin/sh
# Run from the repository root in a disposable Linux environment with cc and git.
set -eu

# Install before testing DB::DuckDB: its child processes do not inherit staging.
# DB::DuckDB 1.0.1 uses File::Temp without declaring it in its test dependencies.
zef install DB Alien::Libduckdb File::Temp
TZ=UTC zef install 'DB::DuckDB:ver<1.0.1>:auth<zef:skyter10086>'

# The driver needs these companion changes for its schema/migration support.
git clone https://github.com/FCO/Red.git .red
git -C .red checkout 589fc491a8544b0d9c2f0a086431256a71322689
git -C .red apply ../tools/red-companion.patch
zef install --/test .red
zef install --test-depends --deps-only .
zef install .
RED_CHECKOUT=.red prove6 -Ilib tools/t

# Check the installed distribution from outside the checkout and without -Ilib.
(cd /tmp && raku -e '
    use Red;
    use Red::Driver::DuckDB;
    model InstallReading {
        has Int $.id is serial;
        has Str $.message is column;
    }
    my $*RED-DB = database "DuckDB";
    InstallReading.^create-table;
    InstallReading.^create(message => "installed in Linux");
    die "Installed driver CRUD failed" unless
        InstallReading.^all.head.message eq "installed in Linux";
    say "Installed driver CRUD OK";
')
