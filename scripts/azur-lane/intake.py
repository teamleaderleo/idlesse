#!/usr/bin/env python3
"""Read-only Android asset intake; no app installs, taps, purchases or broad storage scans."""
import argparse, collections, hashlib, json, re, subprocess, sys
from pathlib import Path


def safe_component(value):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', value) or value in ('.','..'):
        raise ValueError('Unsafe asset/package name')
    return value


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()


def write(path, value):
    temp=path.with_suffix(path.suffix+'.tmp')
    temp.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n');temp.replace(path)


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--serial',required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--plan',type=Path,default=Path(__file__).with_name('candidates.json'))
    p.add_argument('--inspect',action='store_true',help='Also inspect with UnityPy in this Python environment')
    a=p.parse_args();plan=json.loads(a.plan.read_text());package=safe_component(plan['package'])
    root=a.output.resolve();root.mkdir(parents=True,exist_ok=True)
    base='/sdcard/Android/data/'+package+'/files'
    def adb(*argv):
        return subprocess.check_output(['adb','-s',a.serial,*argv],text=True,timeout=120).strip()
    if adb('get-state')!='device':raise RuntimeError('Android is not authorized/reachable')
    version=adb('shell','cat',base+'/version-live2d.txt')
    inventory=adb('shell','ls',base+'/AssetBundles/live2d').splitlines()
    write(root/'inventory.json',{'package':package,'live2dVersion':version,'files':inventory})
    print('Found',len(inventory),'Live2D files; asset version',version,flush=True)
    bundle_root=root/'bundles';bundle_root.mkdir(exist_ok=True)
    report=[]
    for skin in plan['skins']:
        key=safe_component(skin['asset'])
        if key not in inventory:
            report.append({**skin,'status':'not-installed'});continue
        remote=base+'/AssetBundles/live2d/'+key
        size=int(adb('shell','stat','-c','%s',remote))
        if size>64*1024*1024:raise RuntimeError('Bundle exceeds 64 MiB intake budget: '+key)
        source_hash=adb('shell','sha256sum',remote).split()[0]
        if not re.fullmatch('[0-9a-f]{64}',source_hash):raise RuntimeError('Invalid device hash')
        local=bundle_root/key
        if local.exists():
            if sha(local)!=source_hash:
                raise RuntimeError('Source changed; choose a new output directory to preserve prior asset: '+key)
            print('Verified existing:',skin['title'],flush=True)
        else:
            temp=local.with_suffix('.partial')
            adb('pull',remote,str(temp))
            if temp.stat().st_size!=size or sha(temp)!=source_hash:raise RuntimeError('Transfer hash mismatch: '+key)
            temp.replace(local);print('Retrieved:',skin['title'],flush=True)
        item={**skin,'status':'source-verified','package':package,'live2dVersion':version,
              'bytes':size,'sha256':source_hash,'path':str(local)}
        if a.inspect:
            import UnityPy
            env=UnityPy.load(str(local));objects=list(env.objects)
            item['objectTypes']=dict(collections.Counter(o.type.name for o in objects))
            item['textures']=[];item['textAssets']=[]
            for obj in objects:
                if obj.type.name not in ('Texture2D','TextAsset','AnimationClip'):continue
                data=obj.read()
                if obj.type.name=='Texture2D':
                    item['textures'].append({'name':data.m_Name,'width':data.m_Width,'height':data.m_Height})
                elif obj.type.name=='TextAsset':item['textAssets'].append(data.m_Name)
                else:item.setdefault('motions',[]).append(data.m_Name)
        report.append(item);write(root/'receipt.json',report)
    write(root/'receipt.json',report)
    print('Receipt:',root/'receipt.json')
    print('Next: reconstruct Cubism model/motions, render and visually verify. Intake alone is not a playable export.')

if __name__=='__main__':main()
