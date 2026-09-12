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

def stream_info(path):
    return json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
        '-show_entries','stream=codec_name,profile,pix_fmt,color_range,color_space,color_transfer,color_primaries',
        '-of','json',str(path)]))['streams'][0]

def is_main10(stream):
    pixel_format=stream.get('pix_fmt','')
    return stream.get('codec_name')=='hevc' and stream.get('profile')=='Main 10' and ('10' in pixel_format or pixel_format.startswith('p010'))

def gradient_levels(image, columns, channel='g'):
    index={'r':0,'g':1,'b':2}[channel.lower()]
    rgb=image.convert('RGB');pixels=rgb.load();w,h=rgb.size
    if not columns or any(x<0 or x>=w for x in columns):raise ValueError('Gradient columns must fall inside the crop')
    return [len({pixels[x,y][index] for y in range(h)}) for x in columns]

def gradient_precision(video_path, recipe, recipe_dir):
    reference=Path(recipe['reference'])
    if not reference.is_absolute():reference=(recipe_dir/reference).resolve()
    source=Image.open(reference).convert('RGB')
    x,y,w,h=recipe.get('crop',[0,0,source.width,source.height])
    if min(x,y,w,h)<0 or w<1 or h<1 or x+w>source.width or y+h>source.height:
        raise ValueError('Gradient crop falls outside the reference image')
    columns=recipe.get('columns',[w//5,2*w//5,3*w//5,4*w//5])
    channel=recipe.get('channel','g')
    source_crop=source.crop((x,y,x+w,y+h))
    data=subprocess.check_output(['ffmpeg','-v','error','-ss',str(recipe.get('time',0)),'-i',str(video_path),
        '-frames:v','1','-vf',f'crop={w}:{h}:{x}:{y}','-f','rawvideo','-pix_fmt','rgb48le','pipe:1'])
    expected=w*h*6
    if len(data)!=expected:raise RuntimeError(f'Gradient sample decoded {len(data)} bytes; expected {expected}')
    encoded=Image.frombytes('RGB',(w,h),bytes(data[i] for i in range(1,len(data),2)))
    source_levels=gradient_levels(source_crop,columns,channel)
    encoded_levels=gradient_levels(encoded,columns,channel)
    source_mean=sum(source_levels)/len(source_levels);encoded_mean=sum(encoded_levels)/len(encoded_levels)
    gap=source_mean-encoded_mean
    return {'reference':str(reference),'time':recipe.get('time',0),'crop':[x,y,w,h],'columns':columns,'channel':channel,
            'sourceDistinctLevels':source_levels,'encodedDistinctLevels':encoded_levels,
            'sourceMeanDistinctLevels':round(source_mean,2),'encodedMeanDistinctLevels':round(encoded_mean,2),
            'levelGap':round(gap,2),'maxLevelGap':recipe.get('maxLevelGap',9)}

def main():
  p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--job-name',default='batch-2026-09-10')
  p.add_argument('--allow-bars',action='store_true',help='Report letterbox bars instead of exiting non-zero')
  p.add_argument('--require-main10',action='store_true',help='Fail when any checked export is not HEVC Main10 with a 10-bit pixel format')
  p.add_argument('--gradient-plan',type=Path,help='JSON recipes for comparing encoded gradient levels with lossless reference frames')
  a=p.parse_args()
  if Path(a.job_name).name != a.job_name or a.job_name in ('', '.', '..'):p.error('Invalid job name')
  job=a.root/a.job_name;state=json.loads((job/'state.json').read_text());report={}
  plan={}
  if a.gradient_plan:
      raw=json.loads(a.gradient_plan.read_text());plan=raw.get('items',raw)
      if not isinstance(plan,dict):p.error('gradient plan must contain an object of item recipes')
      unknown=set(plan)-set(state['items'])
      if unknown:p.error('gradient plan contains unknown item(s): '+', '.join(sorted(unknown)))
  main10_failures=[];gradient_failures=[]
  for key,item in state['items'].items():
    path=Path(item['path']);frames=int(item['probe']['streams'][0]['nb_read_frames'])
    times=[0,1/60,frames/120,(frames-1)/60]
    samples=[]
    for t in times:
        data=subprocess.check_output(['ffmpeg','-v','error','-ss',str(t),'-i',str(path),'-frames:v','1',
                                      '-vf','scale=512:288','-f','rawvideo','-pix_fmt','rgb24','pipe:1'])
        samples.append(Image.frombytes('RGB',(512,288),data))
    delta=lambda x,y:sum(ImageStat.Stat(ImageChops.difference(x,y)).mean)/3
    edges=bars(samples[0]);stream=stream_info(path)
    report[key]={'seamMeanAbsoluteRGB':delta(samples[0],samples[-1]),
                 'firstStepMeanAbsoluteRGB':delta(samples[0],samples[1]),
                 'firstToMiddleMeanAbsoluteRGB':delta(samples[0],samples[2]),
                 'edgeBarsPixels':edges,'camera':item.get('camera'),'animation':item.get('animation'),
                 'stream':stream,'main10':is_main10(stream),
                 'meaning':'Diagnostic only, except edge bars, requested Main10 and configured gradient checks; no automatic visual/seam approval.'}
    if a.require_main10 and not report[key]['main10']:main10_failures.append((key,stream))
    if key in plan:
        precision=gradient_precision(path,plan[key],a.gradient_plan.parent.resolve())
        report[key]['gradientPrecision']=precision
        if precision['levelGap']>precision['maxLevelGap']:gradient_failures.append((key,precision))
    strip=Image.new('RGB',(1536,288))
    for i,im in enumerate([samples[0],samples[2],samples[3]]):strip.paste(im,(512*i,0))
    strip.save(job/(item['title']+'-qa.jpg'))
  (job/'visual-qa.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
  barred=[(k,v['edgeBarsPixels'],v['camera'],v['animation']) for k,v in report.items() if max(v['edgeBarsPixels'].values())>2]
  for key,edges,camera,animation in barred:
    print(f'WARNING {key}: dead edges {edges}; check the {camera} camera against animation {animation}')
  for key,stream in main10_failures:print(f'ERROR {key}: expected HEVC Main10 10-bit, got {stream}')
  for key,precision in gradient_failures:print(f"ERROR {key}: gradient level gap {precision['levelGap']} exceeds {precision['maxLevelGap']}")
  failures=[]
  if barred and not a.allow_bars:failures.append('Letterbox bars detected; re-check the camera recipe or pass --allow-bars')
  if main10_failures:failures.append('One or more exports failed the Main10 stream check')
  if gradient_failures:failures.append('One or more exports failed gradient precision')
  if failures:raise SystemExit('; '.join(failures))

if __name__ == '__main__': main()
