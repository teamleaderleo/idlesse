#!/usr/bin/env python3
"""Small deterministic loop QA samples; requires Pillow in the study venv."""
import argparse,json,subprocess
from pathlib import Path
from PIL import Image, ImageChops, ImageStat
def bars(im,tolerance=12):
    """Uniform matte around the art, in sample pixels, measured inward from each edge.

    Two framing failures look identical here. A camera recipe tuned on the wrong
    animation pushes the model off-centre and leaves black letterboxing; a model
    fitted by whole-skeleton bounds (transparent effect padding included) strands
    the character in the renderer's background colour. Both are a flat border, so
    the matte colour is read from the corners rather than assumed to be black.

    Corners that disagree mean the art reaches every edge: nothing to report.
    """
    px=im.load();w,h=im.size
    near=lambda a,b:sum(abs(p-q) for p,q in zip(a,b))<=tolerance
    def depth(line,limit):
        """How many consecutive lines from an edge are one flat colour."""
        matte=line(0)[0]
        if not all(near(p,matte) for p in line(0)):return 0
        n=0
        while n<limit and all(near(p,matte) for p in line(n)):n+=1
        return n
    row=lambda y:[px[x,y] for x in range(w)]
    col=lambda x:[px[x,y] for y in range(h)]
    return {'top':depth(lambda n:row(n),h),'bottom':depth(lambda n:row(h-1-n),h),
            'left':depth(lambda n:col(n),w),'right':depth(lambda n:col(w-1-n),w)}

def main():
  p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--job-name',default='batch-2026-09-10')
  p.add_argument('--allow-bars',action='store_true',help='Report letterbox bars instead of exiting non-zero')
  a=p.parse_args()
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
    edges=bars(samples[0])
    report[key]={'seamMeanAbsoluteRGB':delta(samples[0],samples[-1]),
                 'firstStepMeanAbsoluteRGB':delta(samples[0],samples[1]),
                 'firstToMiddleMeanAbsoluteRGB':delta(samples[0],samples[2]),
                 'edgeBarsPixels':edges,'camera':item.get('camera'),'animation':item.get('animation'),
                 'meaning':'Diagnostic only, except edge bars; no automatic visual/seam approval.'}
    strip=Image.new('RGB',(1536,288))
    for i,im in enumerate([samples[0],samples[2],samples[3]]):strip.paste(im,(512*i,0))
    strip.save(job/(item['title']+'-qa.jpg'))
  (job/'visual-qa.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
  barred=[(k,v['edgeBarsPixels'],v['camera'],v['animation']) for k,v in report.items() if max(v['edgeBarsPixels'].values())>2]
  for key,edges,camera,animation in barred:
    print(f'WARNING {key}: dead edges {edges}; check the {camera} camera against animation {animation}')
  if barred and not a.allow_bars:raise SystemExit('Letterbox bars detected; re-check the camera recipe or pass --allow-bars')

if __name__ == '__main__': main()
