#!/usr/bin/env python3
"""Encode a deterministic warm gradient as HEVC Main/Main10 and quantify level retention."""
import argparse,json,platform,subprocess,tempfile,time
from pathlib import Path

WIDTH,HEIGHT,FPS,SECONDS=1100,700,60,1
COLUMNS=(100,350,700,1000)

def source_ppm(path):
    rows=[];green=[]
    for y in range(HEIGHT):
        t=y/(HEIGHT-1)
        r=min(255,int(275-40*t));g=int(174-84*t);b=int(120-40*t)
        green.append(g);rows.append(bytes((r,g,b))*WIDTH)
    path.write_bytes(f'P6\n{WIDTH} {HEIGHT}\n255\n'.encode()+b''.join(rows))
    return green

def encode(ffmpeg,encoder,source,destination,bit_depth):
    command=[ffmpeg,'-hide_banner','-loglevel','error','-y','-loop','1','-framerate',str(FPS),'-i',str(source),
             '-t',str(SECONDS),'-an','-c:v',encoder,'-b:v','40M','-pix_fmt','yuv420p10le' if bit_depth==10 else 'yuv420p']
    if bit_depth==10:command += ['-profile:v','main10']
    if encoder=='libx265':command += ['-x265-params','log-level=error']
    command += ['-tag:v','hvc1',str(destination)]
    started=time.monotonic();subprocess.run(command,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    return time.monotonic()-started

def decode_rgb(ffmpeg,path):
    data=subprocess.check_output([ffmpeg,'-hide_banner','-loglevel','error','-i',str(path),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb48le','pipe:1'])
    expected=WIDTH*HEIGHT*6
    if len(data)!=expected:raise RuntimeError(f'decoded {len(data)} bytes; expected {expected}')
    return data

def levels(data):
    result=[]
    for x in COLUMNS:
        result.append(len({data[(y*WIDTH+x)*6+3] for y in range(HEIGHT)}))
    return result

def mean(values):return sum(values)/len(values)

def stream(ffprobe,path):
    return json.loads(subprocess.check_output([ffprobe,'-v','error','-select_streams','v:0','-show_entries','stream=codec_name,profile,pix_fmt','-of','json',str(path)]))['streams'][0]

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--ffmpeg',default='ffmpeg');p.add_argument('--ffprobe',default='ffprobe')
    p.add_argument('--encoder',default='hevc_videotoolbox' if platform.system()=='Darwin' else 'libx265')
    p.add_argument('--max-main10-gap',type=float,default=9);p.add_argument('--min-eight-bit-gap',type=float,default=5)
    p.add_argument('--output-json',type=Path)
    a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='idlesse-gradient-') as temporary:
        root=Path(temporary);source=root/'source.ppm';g8=root/'main.mp4';g10=root/'main10.mp4'
        source_green=source_ppm(source);source_levels=[len(set(source_green)) for _ in COLUMNS]
        time8=encode(a.ffmpeg,a.encoder,source,g8,8);time10=encode(a.ffmpeg,a.encoder,source,g10,10)
        levels8=levels(decode_rgb(a.ffmpeg,g8));levels10=levels(decode_rgb(a.ffmpeg,g10))
        stream8=stream(a.ffprobe,g8);stream10=stream(a.ffprobe,g10)
        source_mean=mean(source_levels);mean8=mean(levels8);mean10=mean(levels10)
        report={'signal':{'width':WIDTH,'height':HEIGHT,'fps':FPS,'seconds':SECONDS,'columns':list(COLUMNS),'sourceDistinctGreenLevels':source_levels},
                'main8':{'distinctGreenLevels':levels8,'meanDistinctGreenLevels':mean8,'levelGap':round(source_mean-mean8,2),'encodeSeconds':round(time8,3),'bytes':g8.stat().st_size,'stream':stream8},
                'main10':{'distinctGreenLevels':levels10,'meanDistinctGreenLevels':mean10,'levelGap':round(source_mean-mean10,2),'encodeSeconds':round(time10,3),'bytes':g10.stat().st_size,'stream':stream10},
                'ratios':{'encodeTime':round(time10/time8,3),'fileSize':round(g10.stat().st_size/g8.stat().st_size,3)}}
        print(json.dumps(report,indent=2))
        if a.output_json:a.output_json.write_text(json.dumps(report,indent=2)+'\n')
        failures=[]
        if source_mean-mean8<a.min_eight_bit_gap:failures.append('8-bit path did not reproduce the expected gradient-level loss')
        if source_mean-mean10>a.max_main10_gap:failures.append('Main10 gradient-level gap exceeded the single-digit budget')
        if stream10.get('profile')!='Main 10' or '10' not in stream10.get('pix_fmt',''):failures.append('10-bit encode did not produce a Main10 10-bit stream')
        if failures:raise SystemExit('; '.join(failures))

if __name__=='__main__':main()
