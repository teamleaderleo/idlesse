from pathlib import Path
import subprocess,threading,os,sys
from functools import partial
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
r=Path(sys.argv[1]).resolve();destname=sys.argv[2]
class Quiet(SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
s=ThreadingHTTPServer(('127.0.0.1',0),partial(Quiet,directory=str(r)));threading.Thread(target=s.serve_forever,daemon=True).start()
try:
 for p in sorted((r/'models').iterdir()):
  if not p.is_dir():continue
  dest=r/destname/p.name;dest.parent.mkdir(exist_ok=True)
  if (dest/'000000.png').exists():continue
  with dest.with_suffix('.log').open('w') as log:
   code=subprocess.run([str(r/'render'),str(dest),'1','960','540','models/'+p.name,p.name,'normal' if 'spine' in r.name else 'idle','0'],cwd=r,env={**os.environ,'IDLESSE_RENDER_PORT':str(s.server_port)},stdout=log,stderr=log,timeout=120).returncode
  print(p.name,code,flush=True)
finally:s.shutdown();s.server_close()
