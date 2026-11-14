set -eu
python3 - <<'READY'
import socket,time,os
host,port=(os.environ['PGHOST'],5432) if os.environ['BASE_DRIVER']=='Pg' else (os.environ['MYSQL_HOST'],3306)
for attempt in range(90):
 try:
  socket.create_connection((host,port),timeout=1).close();break
 except OSError:
  if attempt==89:raise
  time.sleep(1)
READY
set -eu
mkdir -p /run/check
tar xf /snapshot.tar -C /run/check
cd /run/check/red
set +e
prove6 -j4 --exec='python3 /launcher.py' t > /results/red-suite.log 2>&1
status=$?
printf '%s\n' "$status" > /results/red-suite.exit
if [ "$BASE_DRIVER" = Pg ]; then
 prove6 -j4 --exec='python3 /launcher.py' /run/check/pg/t > /results/driver-suite.log 2>&1
 printf '%s\n' "$?" > /results/driver-suite.exit
elif [ "$BASE_DRIVER" = MySQL ]; then
 prove6 -j4 --exec='python3 /launcher.py' /run/check/mysql/t > /results/driver-suite.log 2>&1
 printf '%s\n' "$?" > /results/driver-suite.exit
fi
exit "$status"
