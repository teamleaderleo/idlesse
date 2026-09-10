#!/usr/bin/env python3
"""Small deterministic loop QA samples; requires Pillow in the study venv."""
import argparse,json,subprocess
from pathlib import Path
from PIL import Image, ImageChops, ImageStat
p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--job-name',default='batch-2026-09-10');a=p.parse_args()
if Path(a.job_name).name != a.job_name or a.job_name in ('', '.', '..'):p.error('Invalid job name')
job=a.root/a.job_name;state=json.loads((job/'state.json').read_text());report={}
for key,item in state['items'].items():
    path=Path(item['path']);frames=int(item['probe']['streams'][0]['nb_read_frames'])
    times=[0,1/60,frames/120,(frames-1)/60]
    samples=[]
    for t in times:
        data=subprocess.check_output(['ffmpeg','-v','error','-ss',str(t),'-i',str(path),'-frames:v','1',
                                      '-vf','scale=512:288','-f','rawvideo','-pix_fmt','rgb24','pipe:1'])
        samples.append(Image.frombytes('RGB',(512,288),data))
    delta=lambda x,y:sum(ImageStat.Stat(ImageChops.difference(x,y)).mean)/3
    report[key]={'seamMeanAbsoluteRGB':delta(samples[0],samples[-1]),
                 'firstStepMeanAbsoluteRGB':delta(samples[0],samples[1]),
                 'firstToMiddleMeanAbsoluteRGB':delta(samples[0],samples[2]),
                 'meaning':'Diagnostic only; no automatic visual/seam approval.'}
    strip=Image.new('RGB',(1536,288))
    for i,im in enumerate([samples[0],samples[2],samples[3]]):strip.paste(im,(512*i,0))
    strip.save(job/(item['title']+'-qa.jpg'))
(job/'visual-qa.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
