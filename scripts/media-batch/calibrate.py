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
    meta_path = Path(str(out) + '.json')
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    return Image.open(out / '000000.png').convert('RGB'), meta


def worst_edges(workspace, server, args, width, height, samples):
    """Framing held across the loop, not just at one instant.

    Characters sway, so a recipe can cover the frame at t=0 and leave a gap a
    second later; measuring one frame is how a barred export passes review.
    Returns the worst matte over the sampled times, plus a frame to look at.
    """
    with tempfile.TemporaryDirectory() as tmp:
        first, meta = render(workspace, server, args.asset, args.stem, args.animation,
                             Path(tmp) / 'f0', width, height, args.seconds)
    duration = next((x['duration'] for x in meta.get('animations', [])
                     if x['name'] == args.animation), 0) or 0
    times = [args.seconds] if samples <= 1 or not duration else \
        [round(args.seconds + duration * i / samples, 4) for i in range(samples)]
    worst, shown = None, first
    for i, t in enumerate(times):
        if i == 0:
            im = first
        else:
            with tempfile.TemporaryDirectory() as tmp:
                im, _ = render(workspace, server, args.asset, args.stem, args.animation,
                               Path(tmp) / 'f', width, height, t)
        e = verify.bars(im.resize((512, 288), Image.LANCZOS))
        if worst is None:
            worst = e
        else:
            if max(e.values()) > max(worst.values()):
                shown = im
            worst = {k: max(worst[k], e[k]) for k in worst}
    return worst, shown, duration


def report(edges, label):
    worst = max(edges.values())
    covered = 100 * (1 - (edges['left'] + edges['right']) / 512) * (1 - (edges['top'] + edges['bottom']) / 288)
    status = 'OK  ' if worst <= 2 else 'MATTE'
    print(f'  {status} {label:22s} edges={edges}  art covers ~{covered:.0f}% of frame')
    return worst


def current_recipe(workspace, stem, animation):
    """Whatever the workspace's cameras.json already says for this stem."""
    path = workspace / 'cameras.json'
    if not path.exists():
        return None
    entry = json.loads(path.read_text()).get(stem)
    if isinstance(entry, list):
        return list(entry)
    if isinstance(entry, dict):
        got = entry.get(animation) or entry.get('default')
        return list(got) if got else None
    return None


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
    p.add_argument('--solve', action='store_true', help='Nudge the recipe until no matte remains, then print it')
    p.add_argument('--solve-from', type=float, nargs=3, metavar=('ZOOM', 'CX', 'CY'), help='Starting recipe for --solve')
    p.add_argument('--rounds', type=int, default=8, help='Maximum --solve iterations')
    p.add_argument('--centre', type=float, nargs=2, default=[0.5, 0.5], metavar=('CX', 'CY'))
    p.add_argument('--seconds', type=float, default=0.0)
    p.add_argument('--size', type=int, nargs=2, default=[1920, 1080], metavar=('W', 'H'))
    p.add_argument('--samples', type=int, default=4,
                   help='Frames spread across the loop to measure; 1 checks only --seconds')
    p.add_argument('--out', type=Path, help='Where to write the preview PNG(s)')
    a = p.parse_args()

    workspace = a.workspace.resolve()
    out_root = (a.out or workspace / 'calibrate').resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    server = serve(workspace)
    width, height = a.size
    restore = None
    try:
        if a.solve:
            camera = list(a.solve_from) if a.solve_from else current_recipe(workspace, a.stem, a.animation) or [1.0, 0.5, 0.5]
            print(f'{a.stem} / {a.animation}, solving from [{camera[0]:g}, {camera[1]:g}, {camera[2]:g}]:')
            for round_ in range(a.rounds):
                restore = patch_cameras(workspace, a.stem, camera) if restore is None else restore
                patch_cameras(workspace, a.stem, camera)
                rebundle(workspace)
                e, im, _ = worst_edges(workspace, server, a, width, height, a.samples)
                print(f'  round {round_+1}: [{camera[0]:g}, {camera[1]:.4g}, {camera[2]:.4g}] -> {e}')
                if max(e.values()) <= 2:
                    im.save(out_root / f'{a.stem}-{a.animation}-solved.png')
                    print(f'\nsolved: [{camera[0]:g}, {camera[1]:.4g}, {camera[2]:.4g}]')
                    print(f'  preview {out_root}/{a.stem}-{a.animation}-solved.png')
                    print('  Look at it: zero matte means the frame is covered, not that the crop is good.')
                    break
                zoom, cx, cy = camera
                # Matte on one side alone is off-centre art and shifts away; matte
                # summed across both sides is art too small for the frame, which no
                # amount of shifting fixes. Zoom to close the total, then recentre on
                # the imbalance. Shifting cx by d moves the art 512*zoom sample px.
                span = e['left'] + e['right']
                if span > 2:
                    zoom *= 512 / max(512 - span - 2, 1)
                    cx += ((e['left'] - e['right']) / 2) / (512 * zoom)
                span = e['top'] + e['bottom']
                if span > 2:
                    zoom *= 288 / max(288 - span - 2, 1)
                    cy += ((e['top'] - e['bottom']) / 2) / (288 * zoom)
                camera = [round(zoom, 4), round(cx, 4), round(cy, 4)]
            else:
                print(f'\nno clean recipe within {a.rounds} rounds; last was {camera}')
            return

        attempts = []
        if a.sweep:
            attempts = [(z, *a.centre) for z in a.sweep]
        elif a.camera:
            attempts = [tuple(a.camera)]

        if not attempts:
            print(f'{a.stem} / {a.animation} with the workspace camera as it stands:')
            e, im, duration = worst_edges(workspace, server, a, width, height, a.samples)
            report(e, f'worst of {a.samples} over {duration:g}s')
            im.save(out_root / f'{a.stem}-{a.animation}-current.png')
            print(f'  wrote {out_root}/{a.stem}-{a.animation}-current.png')
            return

        print(f'{a.stem} / {a.animation}, {len(attempts)} recipe(s):')
        best = None
        for camera in attempts:
            restore = patch_cameras(workspace, a.stem, camera) if restore is None else restore
            patch_cameras(workspace, a.stem, camera)
            rebundle(workspace)
            e, im, _ = worst_edges(workspace, server, a, width, height, a.samples)
            label = f'[{camera[0]:g}, {camera[1]:g}, {camera[2]:g}]'
            worst = report(e, label)
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
