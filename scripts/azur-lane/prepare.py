#!/usr/bin/env python3
"""Prepare only plan-selected public models in existing operator workspaces."""
import argparse,importlib.util,json,subprocess,sys
from pathlib import Path

def main():
 p=argparse.ArgumentParser();p.add_argument('--plan',type=Path,required=True);p.add_argument('--live2d-root',type=Path,required=True);p.add_argument('--spine-root',type=Path,required=True);p.add_argument('--metadata',type=Path,required=True);a=p.parse_args()
 scripts=Path(__file__).parent;spec=importlib.util.spec_from_file_location('fetch_viewer',scripts/'fetch-viewer.py');fetcher=importlib.util.module_from_spec(spec);spec.loader.exec_module(fetcher)
 a.metadata.mkdir(parents=True,exist_ok=True)
 def data(url,name):
  target=a.metadata/name;fetcher.fetch(url,target);return json.loads(target.read_text())
 manifest=data('https://data.nagami.moe/current.json','manifest.json');live=manifest['datasets']['live2d'];spine=manifest['datasets']['spine']
 # Domain and path selection stay fixed; upstream data supplies only revision numbers.
 mapping=data(f'https://data.nagami.moe/live2d/l2d_mapping.json?v={live["version"]}','live2d-mapping.json')
 items=json.loads(a.plan.read_text())['items'];ids=[x['id'] for x in items if x['kind']=='live2d']
 if ids:subprocess.run([sys.executable,str(scripts/'fetch-viewer.py'),'--output',str(a.live2d_root/'models'),*ids],check=True)
 configs={}
 for key in ids:
  config=data(f'https://data.nagami.moe/live2d/skins/{key}.json?v={live["version"]}',key+'-config.json');configs[key]=config
  bg=str(mapping[key]['bg']);fetcher.relative(bg)
  fetcher.fetch(f'https://azlassets.nagami.moe/bg/star_level_bg_{bg}.png',a.live2d_root/'backgrounds'/(bg+'.png'))
 if ids:
  (a.live2d_root/'catalog.json').write_text(json.dumps({k:mapping[k] for k in ids},indent=2))
  (a.live2d_root/'viewer-configs.json').write_text(json.dumps(configs,indent=2))
 for item in items:
  if item['kind']!='spine':continue
  key=item['id'];assert fetcher.relative(key)==key and '/' not in key
  model=data(f'https://data.nagami.moe/spine/models/{key}.json?v={spine["version"]}',key+'-model.json')
  if model.get('images'):raise ValueError('External image layers need renderer support before export')
  root=a.spine_root/'models'/key;root.mkdir(parents=True,exist_ok=True);receipts=[]
  names={n for layer in model['layers'] for n in [layer['skel'],layer['atlas'],*layer['textures']]}
  if len(names)>64:raise ValueError('Spine model file budget exceeded')
  for name in sorted(names):
   name=fetcher.relative(name);receipts.append(fetcher.fetch(f'https://azlassets.nagami.moe/spinepainting/{key}/{name}',root/name))
  (root/'model.json').write_text(json.dumps(model,indent=2));(root/'source-receipt.json').write_text(json.dumps(receipts,indent=2))
 print('Selected model sources prepared; build adapters, preview, then export.')
if __name__=='__main__':main()
