#!/usr/bin/env python3
"""Fetch explicitly selected public Live2D manifests and their bounded local files."""
import argparse,hashlib,json,subprocess
from pathlib import Path,PurePosixPath
from urllib.parse import quote

def relative(value):
 p=PurePosixPath(value)
 if p.is_absolute() or '..' in p.parts or ':' in value or '\\' in value:raise ValueError('Nonlocal model reference')
 return str(p)

def fetch(url,path):
 path.parent.mkdir(parents=True,exist_ok=True)
 if not path.exists():
  temp=path.with_suffix(path.suffix+'.partial')
  try:
   subprocess.run(['curl','-LfsS','--max-time','60','--max-filesize','67108864',url,'-o',str(temp)],check=True)
   temp.replace(path)
  finally:temp.unlink(missing_ok=True)
 return {'path':str(path),'url':url,'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('skins',nargs='+');a=p.parse_args()
 for skin in a.skins:
  if relative(skin)!=skin or '/' in skin:raise ValueError('Invalid skin ID')
  root=a.output/skin;base='https://azlassets.nagami.moe/live2d/'+quote(skin)+'/'
  receipt=[fetch(base+skin+'.model3.json',root/(skin+'.model3.json'))]
  model=json.loads((root/(skin+'.model3.json')).read_text());refs=model['FileReferences'];files=[refs['Moc'],*refs['Textures']]
  files += [refs[k] for k in ('Physics','Pose','DisplayInfo') if refs.get(k)]
  files += [m['File'] for group in refs.get('Motions',{}).values() for m in group]
  files += [m['File'] for m in refs.get('Expressions',[])]
  if len(files)>256:raise ValueError('Too many model files')
  for name in sorted(set(files)):
   name=relative(name);receipt.append(fetch(base+quote(name,safe='/'),root/name))
  (root/'source-receipt.json').write_text(json.dumps({'source':'Third-party viewer mirror of game assets; not an official wallpaper download','files':receipt},indent=2)+'\n')
  print(skin,len(receipt),'files',sum(x['bytes'] for x in receipt),'bytes',flush=True)
if __name__=='__main__':main()
