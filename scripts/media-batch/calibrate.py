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
from collections import deque

spec = importlib.util.spec_from_file_location('verify', Path(__file__).with_name('verify.py'))
verify = importlib.util.module_from_spec(spec); spec.loader.exec_module(verify)
from PIL import Image


# Largest zoom change the solver makes in one round.
MAX_ZOOM_STEP = 1.15


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args): pass


def serve(root):
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(root)))
    # The renderer closes its connections as soon as it has what it needs, which
    # the stock server reports as a traceback; that is not a failure.
    default_error = server.handle_error
    server.handle_error = lambda request, address: None if isinstance(sys.exc_info()[1], (ConnectionError, BrokenPipeError)) \
        else default_error(request, address)
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
        # Measured at the render's own size and then expressed in the 512x288
        # sample space the solver works in. Downscaling first smeared thin
        # strips below the gate, which is how this approved Ibuki's 106px gap.
        native = verify.bars(im)
        sx, sy = 512 / im.width, 288 / im.height
        e = {k: (v * sx if k in ('left', 'right') else v * sy) for k, v in native.items()}
        e['_native'] = max(native.values())
        if worst is None:
            worst = e
        else:
            if e['_native'] > worst['_native']:
                shown = im
            worst = {k: max(worst[k], e[k]) for k in worst}
    return worst, shown, duration


def next_camera(camera, e):
    """One solver step: the recipe that should close the matte measured in `e`."""
    zoom, cx, cy = camera
    start = zoom
    # Matte on one side alone is off-centre art and shifts away; matte
    # summed across both sides is art too small for the frame, which no
    # amount of shifting fixes. Zoom to close the total, then recentre on
    # the imbalance. Shifting cx by d moves the art 512*zoom sample px.
    # Any remaining matte gets corrected: the clean check above is in
    # native pixels, and a gap under two sample pixels is still a gap.
    span = e['left'] + e['right']
    if span > 0:
        zoom *= 512 / max(512 - span - 2, 1)
        cx += ((e['left'] - e['right']) / 2) / (512 * zoom)
    span = e['top'] + e['bottom']
    if span > 0:
        zoom *= 288 / max(288 - span - 2, 1)
        cy += ((e['top'] - e['bottom']) / 2) / (288 * zoom)
    # A wedge in a corner measures nearly the whole edge as depth, and
    # the bar formula divides by what is left: it once "solved" Saori at
    # zoom 302, a patch of art with no matte in it. Step instead, so the
    # first clean round is the smallest zoom that covers the frame.
    if zoom > start * MAX_ZOOM_STEP:
        zoom = start * MAX_ZOOM_STEP
    return [round(zoom, 4), round(cx, 4), round(cy, 4)]


# --- fitting by the painted area -------------------------------------------
#
# The step solver above zooms on the imbalance of matte across edges, which is
# right for a strip and wrong for an irregular painted area: on a lobby whose art
# has a notch in one corner it recentres towards the notch and zooms far past
# what is needed. Measuring the painted area directly avoids that: render the
# whole scene zoomed out, mark the matte, and frame the largest box that is clear
# of it through the whole loop.


def matte_mask(im, gw=192, gh=108):
    """Matte reachable from the frame edge, on a coarse grid. Dark art inside the
    picture never connects to the edge through matte-coloured pixels, so flood
    filling from the border separates the renderer's background from painted black."""
    small = im.convert('RGB').resize((gw, gh))
    px = small.load()
    tol = verify.MATTE_TOLERANCE + 2  # resampling blends edges slightly
    def is_matte(c):
        return any(all(abs(c[i] - m[i]) <= tol for i in range(3)) for m in verify.RENDER_MATTES)
    mask = [[False] * gw for _ in range(gh)]
    queue = deque((x, y) for x in range(gw) for y in (0, gh - 1))
    queue.extend((x, y) for y in range(gh) for x in (0, gw - 1))
    seen = set()
    while queue:
        x, y = queue.popleft()
        if (x, y) in seen or not (0 <= x < gw and 0 <= y < gh):
            continue
        seen.add((x, y))
        if not is_matte(px[x, y]):
            continue
        mask[y][x] = True
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return mask

def largest_box(masks, gw=192, gh=108, centre=(0.5, 0.5)):
    """The largest frame-shaped box clear of matte in every mask, as a unit
    (x, y, w, h); the one nearest `centre` when several tie."""
    union = [[any(m[y][x] for m in masks) for x in range(gw)] for y in range(gh)]
    # Grow each matte cell by one so the box keeps clear of resampled edges.
    grown = [[union[y][x] or any(union[yy][xx] for yy in (y-1, y, y+1) for xx in (x-1, x, x+1) if 0 <= yy < gh and 0 <= xx < gw) for x in range(gw)] for y in range(gh)]
    prefix = [[0] * (gw + 1) for _ in range(gh + 1)]
    for y in range(gh):
        row = 0
        for x in range(gw):
            row += grown[y][x]
            prefix[y + 1][x + 1] = prefix[y][x + 1] + row
    def empty(x, y, w, h):
        return prefix[y + h][x + w] - prefix[y][x + w] - prefix[y + h][x] + prefix[y][x] == 0
    for h in range(gh, 8, -1):
        w = round(h * gw / gh)
        best = None
        for y in range(gh - h + 1):
            for x in range(gw - w + 1):
                if empty(x, y, w, h):
                    d = (x + w / 2 - centre[0] * gw) ** 2 + (y + h / 2 - centre[1] * gh) ** 2
                    if best is None or d < best[0]:
                        best = (d, x, y)
        if best:
            _, x, y = best
            return (x / gw, y / gh, w / gw, h / gh)
    return None


def fit_to_painted_area(workspace, server, asset, stem, animation, duration, bounds, apply, samples=8):
    """A camera framing the largest matte-free box of the whole scene, or None.

    `apply(camera)` must install a recipe in the workspace. The scene is sampled
    with the skeleton's bounds contained in the frame rather than covering it,
    since the default cover fit already crops away art the box could use.
    """
    if not bounds or not bounds.get('width') or not bounds.get('height'):
        return None
    across, down = 1920 / bounds['width'], 1080 / bounds['height']
    overview = [round(min(across, down) / max(across, down), 4), 0.5, 0.5]
    apply(overview)
    masks = []
    for i in range(samples):
        with tempfile.TemporaryDirectory() as tmp:
            im, _ = render(workspace, server, asset, stem, animation, Path(tmp) / 'f', 1920, 1080, duration * i / samples)
        masks.append(matte_mask(im))
    box = largest_box(masks)
    if not box:
        return None
    zoom, cx, cy = overview
    x, y, w, h = box
    return [round(zoom / max(w, h), 4), round(cx + (x + w / 2 - 0.5) / zoom, 4), round(cy + (y + h / 2 - 0.5) / zoom, 4)]


def clean(edges):
    return edges['_native'] <= verify.MATTE_TOLERANCE


def report(edges, label):
    worst = edges['_native']
    edges = {k: round(v, 1) for k, v in edges.items() if k != '_native'}
    covered = 100 * (1 - (edges['left'] + edges['right']) / 512) * (1 - (edges['top'] + edges['bottom']) / 288)
    status = 'OK  ' if worst <= verify.MATTE_TOLERANCE else 'MATTE'
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
                shown = {k: round(v, 1) for k, v in e.items() if k != '_native'}
                print(f'  round {round_+1}: [{camera[0]:g}, {camera[1]:.4g}, {camera[2]:.4g}] -> {shown}, worst {e["_native"]}px')
                if clean(e):
                    im.save(out_root / f'{a.stem}-{a.animation}-solved.png')
                    print(f'\nsolved: [{camera[0]:g}, {camera[1]:.4g}, {camera[2]:.4g}]')
                    print(f'  preview {out_root}/{a.stem}-{a.animation}-solved.png')
                    print('  Look at it: zero matte means the frame is covered, not that the crop is good.')
                    break
                camera = next_camera(camera, e)
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
