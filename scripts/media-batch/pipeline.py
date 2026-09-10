#!/usr/bin/env python3
"""One-command batch: restore → render → verify → optional Drive archive."""
import argparse,subprocess,sys
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--root',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--drive',type=Path)
p.add_argument('--plan',type=Path,default=Path(__file__).with_name('batch.json'))
p.add_argument('--frame-asset',action='append',default=[])
p.add_argument('--port',type=int,default=18763)
p.add_argument('--job-name',default='batch-2026-09-10')
p.add_argument('--qa-python',type=Path,help='Python with Pillow; defaults to workspace .venv/bin/python')
a=p.parse_args();scripts=Path(__file__).resolve().parent;root=a.root.resolve()
qa=a.qa_python or root/'.venv/bin/python'
subprocess.run([str(qa),'-c','from PIL import Image'],check=True)
subprocess.run([sys.executable,str(scripts/'run.py'),'--root',str(root),'--output',str(a.output.resolve()),'--plan',str(a.plan.resolve()),'--job-name',a.job_name,'--port',str(a.port)]+[v for key in a.frame_asset for v in ['--frame-asset',key]],check=True)
subprocess.run([str(qa),str(scripts/'verify.py'),'--root',str(root),'--job-name',a.job_name],check=True)
if a.drive:
    subprocess.run([sys.executable,str(scripts/'archive.py'),'--root',str(root),'--drive',str(a.drive.resolve()),'--job-name',a.job_name],check=True)
print('Batch prepared. Review QA strips and import the verified MP4s into Library; remote Drive sync is independent.')
