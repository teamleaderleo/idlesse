#!/usr/bin/env python3
"""Bounded deterministic WebCodecs export with a loopback-only output receiver."""
import argparse,json,os,secrets,subprocess,threading
from functools import partial
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from pathlib import Path

def main():
 p=argparse.ArgumentParser();p.add_argument('output',type=Path);p.add_argument('count',type=int);p.add_argument('width',type=int);p.add_argument('height',type=int);p.add_argument('folder');p.add_argument('stem');p.add_argument('animation');a=p.parse_args()
 if not 1<=a.count<=5400 or (a.width,a.height)!=(3840,2160):p.error('Export exceeds the 4K/90-second budget')
 try: bit_depth=int(os.environ.get('IDLESSE_EXPORT_BIT_DEPTH','10'))
 except ValueError: p.error('IDLESSE_EXPORT_BIT_DEPTH must be 8 or 10')
 if bit_depth not in (8,10):p.error('IDLESSE_EXPORT_BIT_DEPTH must be 8 or 10')
 root=Path.cwd();dest=a.output.resolve();dest.parent.mkdir(parents=True,exist_ok=True)
 if dest.exists():p.error('Output already exists')
 partial_path=dest.with_suffix('.mp4.upload');token=secrets.token_hex(24);received=False
 class Handler(SimpleHTTPRequestHandler):
  def log_message(self,*args):pass
  def handle(self):
   try:super().handle()
   except (ConnectionResetError,BrokenPipeError):pass
  def do_POST(self):
   nonlocal received
   try:n=int(self.headers.get('Content-Length','0'))
   except ValueError:self.send_error(400);return
   if self.path!='/'+token or received or not 0<n<=512*1024*1024:self.send_error(400);return
   if self.headers.get('Origin') not in (None,f'http://127.0.0.1:{self.server.server_port}'):self.send_error(403);return
   self.connection.settimeout(60)
   try:
    with partial_path.open('wb') as f:
     while n:
      chunk=self.rfile.read(min(n,1024*1024))
      if not chunk:raise IOError('Incomplete encoded output')
      f.write(chunk);n-=len(chunk)
    received=True;self.send_response(200);self.send_header('Content-Length','0');self.end_headers()
   except (OSError,TimeoutError):partial_path.unlink(missing_ok=True);raise
 server=ThreadingHTTPServer(('127.0.0.1',0),partial(Handler,directory=str(root)))
 threading.Thread(target=server.serve_forever,daemon=True).start()
 code=dest.with_suffix('.encode.js');meta=Path(str(dest)+'.json')
 code.write_text('return await window.fastExport('+','.join(json.dumps(v) for v in [a.folder,a.stem,a.animation,a.count,a.width,a.height,'/'+token,bit_depth])+');')
 try:
  subprocess.run([str(root/'encode'),f'http://127.0.0.1:{server.server_port}/index.html',str(code),str(meta)],check=True,timeout=1850)
  if not received:raise RuntimeError('Encoder returned without a complete file')
  result=json.loads(meta.read_text())
  if result['frames']!=a.count or result['bytes']!=partial_path.stat().st_size:raise RuntimeError('Incomplete encoder receipt')
  probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=codec_name,profile,pix_fmt','-of','json',str(partial_path)]))['streams'][0]
  result['stream']=probe
  if bit_depth==10 and (probe.get('profile')!='Main 10' or '10' not in probe.get('pix_fmt','')):
   raise RuntimeError('WebCodecs returned '+str(probe)+' instead of a 10-bit HEVC Main10 stream')
  meta.write_text(json.dumps(result,sort_keys=True))
  partial_path.replace(dest)
  print('Encoded',a.count,'frames in',result['encodeSeconds'],'seconds as',probe.get('profile'),probe.get('pix_fmt'),flush=True)
 finally:
  server.shutdown();server.server_close();code.unlink(missing_ok=True);partial_path.unlink(missing_ok=True)
if __name__=='__main__':main()
