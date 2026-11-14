import os,sys,subprocess,json,time,signal
from pathlib import Path
kind=os.environ['BASE_DRIVER'];test=Path(sys.argv[-1]).resolve();root=Path('/run/check')
env=os.environ.copy();env['RED_SOURCE']=str(root/'red')
if kind=='Pg': cmd=['bash',str(root/'pg/tools/pg-test-exec.sh'),str(test)]
elif kind=='MySQL': cmd=['raku',str(root/'mysql/tools/red-test-exec.raku'),str(test)]
else:
 env['RED_DATABASE']='SQLite';cmd=['raku','-I'+str(root/'red/lib'),str(test)]
start=time.monotonic();p=subprocess.Popen(cmd,cwd=root/'red',env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
try: out,err=p.communicate(timeout=600);code=p.returncode
except subprocess.TimeoutExpired:
 os.killpg(p.pid,signal.SIGKILL);out,err=p.communicate();out+=b'\nBail out! timeout\n';code=124
prefix=Path('/results')/test.name
Path(str(prefix)+'.tap').write_bytes(out);Path(str(prefix)+'.stderr.log').write_bytes(err)
Path(str(prefix)+'.json').write_text(json.dumps(dict(file=str(test),driver=kind,exit_code=code,timeout_seconds=600,seconds=round(time.monotonic()-start,2),command=cmd),indent=2))
sys.stdout.buffer.write(out.replace(b'Bail out!',b'# Original Bail out!'));sys.stdout.flush();sys.stderr.buffer.write(err);sys.exit(code)
