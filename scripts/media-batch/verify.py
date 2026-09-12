#!/usr/bin/env python3
"""Small deterministic loop QA samples; requires Pillow in the study venv."""
import argparse,json,subprocess
from pathlib import Path
from PIL import Image, ImageChops, ImageStat
# Renderer clear colours: the lobby harness clears to black, the Azur spine
# adapter to 0x18202b. Matte is exactly these, so they are named rather than
# guessed from corner pixels, which on flat-painted art are often the art.
RENDER_MATTES=((0,0,0),(24,32,43))

def bars(im,tolerance=12,mattes=RENDER_MATTES,min_run=0.1):
    """Renderer matte around the art, in the image's pixels, inward from each edge.

    Measured per line rather than per edge. A camera that leaves a wedge or a
    strip down part of one edge is as visible as full letterboxing, but no whole
    row or column of it is matte, and an earlier version that required one
    passed 44 of 117 exports with visible gaps -- Nagisa's 69px corner, Ibuki's
    106px strip -- as clean.

    Two things are not counted. A line that is matte along its whole length
    belongs to the bar on the perpendicular edge, and counting it here would
    report that bar's full span twice. And dark art touching the frame, hair or
    an outline, is matte-coloured for a few scattered lines; a run has to cover
    ``min_run`` of the edge before it counts.
    """
    px=im.load();w,h=im.size
    def near(p,m):return abs(p[0]-m[0])+abs(p[1]-m[1])+abs(p[2]-m[2])<=tolerance
    def edge(count,limit,at):
        best=0
        for m in mattes:
            depths=[]
            for i in range(count):
                n=0
                while n<limit and near(at(i,n),m):n+=1
                depths.append(n)
            if all(d==limit for d in depths):return limit
            run,peak,need=0,0,max(1,int(count*min_run))
            for d in depths+[0]:
                if 0<d<limit:
                    run+=1;peak=max(peak,d)
                else:
                    if run>=need:best=max(best,peak)
                    run,peak=0,0
        return best
    return {'top':edge(w,h,lambda i,n:px[i,n]),'bottom':edge(w,h,lambda i,n:px[i,h-1-n]),
            'left':edge(h,w,lambda i,n:px[n,i]),'right':edge(h,w,lambda i,n:px[w-1-n,i])}

# Native pixels of matte tolerated on any edge. Measured at full resolution:
# a downscaled check smears a 12px strip into one blended sample pixel.
MATTE_TOLERANCE=3

def worst_edges(path,times,stream):
    """Matte at full resolution, worst over the sampled frames.

    Characters sway, so a gap can open after the first frame; checking only
    t=0 is how barred exports have passed review before.
    """
    w,h=int(stream['width']),int(stream['height']);worst=None
    for t in times:
        data=subprocess.check_output(['ffmpeg','-v','error','-ss',str(t),'-i',str(path),'-frames:v','1',
                                      '-f','rawvideo','-pix_fmt','rgb24','pipe:1'])
        e=bars(Image.frombytes('RGB',(w,h),data))
        worst=e if worst is None else {k:max(worst[k],e[k]) for k in e}
    return worst

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
    edges=worst_edges(path,times,item['probe']['streams'][0])
    report[key]={'seamMeanAbsoluteRGB':delta(samples[0],samples[-1]),
                 'firstStepMeanAbsoluteRGB':delta(samples[0],samples[1]),
                 'firstToMiddleMeanAbsoluteRGB':delta(samples[0],samples[2]),
                 'edgeBarsPixels':edges,'camera':item.get('camera'),'animation':item.get('animation'),
                 'meaning':'Diagnostic only, except edge bars; no automatic visual/seam approval.'}
    strip=Image.new('RGB',(1536,288))
    for i,im in enumerate([samples[0],samples[2],samples[3]]):strip.paste(im,(512*i,0))
    strip.save(job/(item['title']+'-qa.jpg'))
  (job/'visual-qa.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
  barred=[(k,v['edgeBarsPixels'],v['camera'],v['animation']) for k,v in report.items() if max(v['edgeBarsPixels'].values())>MATTE_TOLERANCE]
  for key,edges,camera,animation in barred:
    print(f'WARNING {key}: dead edges {edges}; check the {camera} camera against animation {animation}')
  if barred and not a.allow_bars:raise SystemExit('Letterbox bars detected; re-check the camera recipe or pass --allow-bars')

if __name__ == '__main__': main()
