#!/usr/bin/env python3
"""One-command batch: restore → render → verify → optional Drive archive."""
import argparse,subprocess,sys
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--root',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--drive',type=Path)
p.add_argument('--qa-python',type=Path,help='Python with Pillow; defaults to workspace .venv/bin/python')
a=p.parse_args();scripts=Path(__file__).resolve().parent;root=a.root.resolve()
qa=a.qa_python or root/'.venv/bin/python'
subprocess.run([str(qa),'-c','from PIL import Image'],check=True)
subprocess.run([sys.executable,str(scripts/'run.py'),'--root',str(root),'--output',str(a.output.resolve())],check=True)
subprocess.run([str(qa),str(scripts/'verify.py'),'--root',str(root)],check=True)
if a.drive:
    subprocess.run([sys.executable,str(scripts/'archive.py'),'--root',str(root),'--drive',str(a.drive.resolve())],check=True)
print('Batch prepared. Review QA strips and import the verified MP4s into Library; remote Drive sync is independent.')
