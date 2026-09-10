#!/usr/bin/env python3
"""Copy verified batch deliverables into an existing Drive sync root; never evict playback files."""
import argparse, hashlib, json, shutil, zipfile
from pathlib import Path

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()

def copy_verified(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    expected=sha(source)
    if target.exists():
        if sha(target)!=expected: raise RuntimeError('Refusing changed destination: '+str(target))
    else:
        temp=target.with_suffix(target.suffix+'.partial')
        shutil.copy2(source,temp)
        if sha(temp)!=expected: raise RuntimeError('Copy hash mismatch')
        temp.replace(target)
    return {'path':str(target),'sha256':expected,'bytes':target.stat().st_size}

p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--drive',type=Path,required=True)
p.add_argument('--job-name',default='batch-2026-09-10')
a=p.parse_args();root=a.root.resolve();drive=a.drive.resolve()
if Path(a.job_name).name != a.job_name or a.job_name in ('', '.', '..'):p.error('Invalid job name')
if not drive.is_dir():raise RuntimeError('Drive root does not exist')
job=root/a.job_name;state=json.loads((job/'state.json').read_text())
if state.get('phase')!='exports-verified-awaiting-visual-review-and-import':raise RuntimeError('Exports incomplete')
receipt=[]
for key,item in state['items'].items():
    video=Path(item['path'])
    if sha(video)!=item['sha256']:raise RuntimeError('Playback file changed')
    folder=drive/'Restored/Blue Archive'/item['title']
    receipt.append(copy_verified(video,folder/video.name))
    receipt.append(copy_verified(video.with_suffix('.source.json'),folder/video.with_suffix('.source.json').name))
    poster=video.parent/(item['title']+'.jpg')
    receipt.append(copy_verified(poster,drive/'Previews/Blue Archive'/(item['title']+'.jpg')))
archive=job/'source-and-restored-assets.zip'
if not archive.exists():
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_STORED) as z:
        for base in ('assets-pc','assets-ai-batch'):
            for key in state['items']:
                for file in sorted((root/base/key).iterdir()):
                    if file.is_file():z.write(file,str(file.relative_to(root)))
receipt.append(copy_verified(archive,drive/'Originals/Blue Archive'/('Batch-2026-09-10' if a.job_name == 'batch-2026-09-10' else a.job_name)/archive.name))
(job/'drive-copy-receipt.json').write_text(json.dumps({'status':'local-sync-folder-copies-hash-verified; remote sync unverified','files':receipt},indent=2))
print('Copied and hash-verified',len(receipt),'files;',sum(i['bytes'] for i in receipt),'bytes. Remote sync not implied.')
