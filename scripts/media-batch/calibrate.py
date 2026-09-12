#!/usr/bin/env python3
"""Render one frame for a camera recipe and say whether it frames the scene.

Camera recipes are the step that has cost us the most rework: they are read from
the posed skeleton, so a recipe is only valid for the animation it was tuned on,
and a wrong one is invisible until a full export has been paid for. This renders
a single frame, measures the matte around the art, and writes a PNG to look at.

    python3 scripts/media-batch/calibrate.py --workspace build/azur-spine \\
        --asset models/hu_2 --stem hu_2 --animation normal --camera 3.25 0.5 0.5

Omit --camera to see what the workspace's own cameras.json currently produces.
With --sweep it renders a grid of zooms and reports the matte for each, so a
usable starting recipe can be picked without editing anything.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, threading
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import importlib.util

spec = importlib.util.spec_from_file_location('verify', Path(__file__).with_name('verify.py'))
verify = importlib.util.module_from_spec(spec); spec.loader.exec_module(verify)
from PIL import Image


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args): pass


def serve(root):
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def render(workspace, server, asset, stem, animation, out, width, height, seconds):
    binary = workspace / 'render'
    if not binary.exists():
        sys.exit(f'No renderer at {binary}; build the workspace first (see the pipeline README).')
    subprocess.run([str(binary), str(out), '1', str(width), str(height), asset, stem, animation, str(seconds)],
                   cwd=workspace, check=True, capture_output=True,
                   env={**os.environ, 'IDLESSE_RENDER_PORT': str(server.server_port)})
    return Image.open(out / '000000.png').convert('RGB')


def report(im, label):
    small = im.resize((512, 288), Image.LANCZOS)
    edges = verify.bars(small)
    worst = max(edges.values())
    covered = 100 * (1 - (edges['left'] + edges['right']) / 512) * (1 - (edges['top'] + edges['bottom']) / 288)
    status = 'OK  ' if worst <= 2 else 'MATTE'
    print(f'  {status} {label:22s} edges={edges}  art covers ~{covered:.0f}% of frame')
    return worst


def patch_cameras(workspace, stem, camera):
    """Write a recipe into the workspace's cameras.json, keeping a restore copy."""
    path = workspace / 'cameras.json'
    original = path.read_text() if path.exists() else None
    data = json.loads(original) if original else {}
    data[stem] = list(camera)
    path.write_text(json.dumps(data, indent=2) + '\n')
    return original


def rebundle(workspace):
    esbuild = workspace / 'node_modules/.bin/esbuild'
    if not esbuild.exists():
        sys.exit(f'No esbuild at {esbuild}; cannot rebuild the renderer bundle.')
    subprocess.run([str(esbuild), 'render.js', '--bundle', '--outfile=render.bundle.js'],
                   cwd=workspace, check=True, capture_output=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--workspace', type=Path, required=True, help='Prepared render workspace')
    p.add_argument('--asset', required=True, help='Asset folder relative to the workspace')
    p.add_argument('--stem', required=True)
    p.add_argument('--animation', required=True)
    p.add_argument('--camera', type=float, nargs=3, metavar=('ZOOM', 'CX', 'CY'))
    p.add_argument('--sweep', type=float, nargs='+', metavar='ZOOM', help='Try these zooms at the given centre')
    p.add_argument('--centre', type=float, nargs=2, default=[0.5, 0.5], metavar=('CX', 'CY'))
    p.add_argument('--seconds', type=float, default=0.0)
    p.add_argument('--size', type=int, nargs=2, default=[1920, 1080], metavar=('W', 'H'))
    p.add_argument('--out', type=Path, help='Where to write the preview PNG(s)')
    a = p.parse_args()

    workspace = a.workspace.resolve()
    out_root = (a.out or workspace / 'calibrate').resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    server = serve(workspace)
    width, height = a.size
    restore = None
    try:
        attempts = []
        if a.sweep:
            attempts = [(z, *a.centre) for z in a.sweep]
        elif a.camera:
            attempts = [tuple(a.camera)]

        if not attempts:
            print(f'{a.stem} / {a.animation} with the workspace camera as it stands:')
            with tempfile.TemporaryDirectory() as tmp:
                im = render(workspace, server, a.asset, a.stem, a.animation, Path(tmp), width, height, a.seconds)
            report(im, 'current')
            im.save(out_root / f'{a.stem}-{a.animation}-current.png')
            print(f'  wrote {out_root}/{a.stem}-{a.animation}-current.png')
            return

        print(f'{a.stem} / {a.animation}, {len(attempts)} recipe(s):')
        best = None
        for camera in attempts:
            restore = patch_cameras(workspace, a.stem, camera) if restore is None else restore
            patch_cameras(workspace, a.stem, camera)
            rebundle(workspace)
            with tempfile.TemporaryDirectory() as tmp:
                im = render(workspace, server, a.asset, a.stem, a.animation, Path(tmp), width, height, a.seconds)
            label = f'[{camera[0]:g}, {camera[1]:g}, {camera[2]:g}]'
            worst = report(im, label)
            name = out_root / f'{a.stem}-{a.animation}-z{camera[0]:g}.png'
            im.save(name)
            if best is None or worst < best[0]:
                best = (worst, camera, name)
        if best:
            print(f'\nbest: [{best[1][0]:g}, {best[1][1]:g}, {best[1][2]:g}]  ->  {best[2]}')
            print('Look at it before trusting it; low matte is necessary, not sufficient.')
    finally:
        if restore is not None:
            (workspace / 'cameras.json').write_text(restore)
            rebundle(workspace)
            print('(workspace cameras.json restored; commit the recipe you chose to the tracked copy)')
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
