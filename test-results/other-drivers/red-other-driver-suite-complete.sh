set -eu
raku - <<'READY'
my ($host, $port) = %*ENV<BASE_DRIVER> eq 'Pg'
    ?? (%*ENV<PGHOST>, 5432) !! (%*ENV<MYSQL_HOST>, 3306);
for ^90 -> $attempt {
    my $socket = try IO::Socket::INET.new(:$host, :$port, :timeout(1));
    if $socket.defined { $socket.close; last }
    die "Database at $host:$port did not become ready" if $attempt == 89;
    sleep 1;
}
READY
set -eu
mkdir -p /run/check
tar xf /snapshot.tar -C /run/check
cd /run/check/red
set +e
prove6 -j4 --exec='raku /launcher.raku' t > /results/red-suite.log 2>&1
status=$?
printf '%s\n' "$status" > /results/red-suite.exit
if [ "$BASE_DRIVER" = Pg ]; then
 prove6 -j4 --exec='raku /launcher.raku' /run/check/pg/t > /results/driver-suite.log 2>&1
 printf '%s\n' "$?" > /results/driver-suite.exit
elif [ "$BASE_DRIVER" = MySQL ]; then
 prove6 -j4 --exec='raku /launcher.raku' /run/check/mysql/t > /results/driver-suite.log 2>&1
 printf '%s\n' "$?" > /results/driver-suite.exit
fi
exit "$status"
