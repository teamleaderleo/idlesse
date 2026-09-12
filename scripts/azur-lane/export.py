#!/usr/bin/env python3
"""Export an explicitly reviewed local model plan; no downloads or GPU billing."""
import argparse,fcntl,importlib.util,json,re,subprocess,time
from pathlib import Path

def main():
 p=argparse.ArgumentParser();p.add_argument('--plan',type=Path,required=True);p.add_argument('--live2d-root',type=Path,required=True);p.add_argument('--spine-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--job',type=Path,required=True);a=p.parse_args()
 scripts=Path(__file__).resolve().parents[1]/'media-batch';spec=importlib.util.spec_from_file_location('batch',scripts/'run.py');batch=importlib.util.module_from_spec(spec);spec.loader.exec_module(batch)
 a.job.mkdir(parents=True,exist_ok=True);a.output.mkdir(parents=True,exist_ok=True);state_path=a.job/'state.json'
 with (a.job/'lock').open('w') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  state=json.loads(state_path.read_text()) if state_path.exists() else {'items':{}}
  for item in json.loads(a.plan.read_text())['items']:
   key=item['id'];root=(a.live2d_root if item['kind']=='live2d' else a.spine_root).resolve()
   title=re.sub('-+', '-', re.sub(r'[^\w.-]+','-',item['title'])).strip('-');final=a.output/(title+'-4K60.mp4')
   prior=state['items'].get(key)
   if prior:
    if final.exists() and batch.digest(final)==prior['sha256']:print('Verified checkpoint',key,flush=True);continue
    raise RuntimeError('Changed completed output: '+key)
   if final.exists():raise RuntimeError('Untracked output: '+str(final))
   meta=json.loads((root/'final-previews'/(key+'.json')).read_text());duration=next(x['duration'] for x in meta['animations'] if x['name']==item['animation']);frames=round(duration*60)
   if not 1<=frames<=5400:raise ValueError('Loop exceeds export budget')
   if item['kind']=='spine':
    for layer in meta['layerAnimations']:
     d=next(x['duration'] for x in layer if x['name']==item['animation'])
     if round(d*60) and frames%round(d*60):raise ValueError('Different layer periods require a reviewed common loop')
   temp=a.job/(key+'.mp4');temp=temp.resolve()
   if temp.exists():raise RuntimeError('Inspect incomplete temporary output before retry: '+str(temp))
   start=time.monotonic()
   with (a.job/(key+'.log')).open('w') as log:
    subprocess.run(['python3',str(scripts/'encode.py'),str(temp),str(frames),'3840','2160','models/'+key,key,item['animation']],cwd=root,stdout=log,stderr=log,check=True,timeout=1900)
   verified=batch.probe(temp);stream=verified['streams'][0]
   rendered=json.loads(Path(str(temp)+'.json').read_text()) if Path(str(temp)+'.json').exists() else {}
   assert (stream['width'],stream['height'],stream['r_frame_rate'],int(stream['nb_read_frames']))==(3840,2160,'60/1',frames)
   poster=a.output/(title+'.jpg');subprocess.run(['ffmpeg','-v','error','-y','-ss',str(min(2,duration/2)),'-i',str(temp),'-frames:v','1','-vf','scale=1024:-2','-q:v','3',str(poster)],check=True)
   temp.replace(final)
   receipt={**item,'path':str(final.resolve()),'poster':str(poster.resolve()),'sha256':batch.digest(final),'probe':verified,'camera':rendered.get('camera'),'seconds':round(time.monotonic()-start,2),'source':'Game assets mirrored by azurlane.nagami.moe; not an official wallpaper download','sourceAssetResolution':'Original downloaded textures, rendered at 4K; not AI-upscaled','limitations':'Idle only; no interactive gestures, audio or Unity-specific effects. Visual loop review required.'}
   batch.save(final.with_suffix('.source.json'),receipt);state['items'][key]=receipt;batch.save(state_path,state);print('Completed',item['title'],frames,'frames',receipt['seconds'],'seconds',flush=True)
if __name__=='__main__':main()
