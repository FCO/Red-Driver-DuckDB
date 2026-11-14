set -eu
mkdir -p /run/check
tar xf /snapshot.tar -C /run/check
cd /run/check/red
python3 /launcher.py /run/check/red/t/154-migration-five-levels.rakutest > /results/test.log 2>&1
