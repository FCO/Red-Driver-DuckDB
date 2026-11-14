set -eu
mkdir -p /run/check
tar xf /snapshot.tar -C /run/check
cd /run/check/red
raku /launcher.raku /run/check/red/t/154-migration-five-levels.rakutest > /results/test.log 2>&1
