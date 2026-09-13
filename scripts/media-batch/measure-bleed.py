#!/usr/bin/env python3
"""Measure the painted margin (bleed) on each edge of an exported wallpaper.

Bleed is low-detail margin the artist painted past the intended composition.
It reads like matte to the edge check in `verify.py` (which only asks whether an
edge is *uniform*), so it survives export -- and then a display whose aspect
matches the export crops nothing and shows it. Declaring it in a
`<name>.framing.json` sidecar lets every display crop at least that much.

This reports where the composition actually ends. It does not decide for you:
the boundary between "margin" and "art the artist meant" is a judgement call,
so it prints the profile it measured and you confirm before writing.

Needs only ffmpeg/ffprobe and the standard library.
"""
import argparse, json, os, subprocess, sys, tempfile

def probe(path):
    out = subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height:format=duration', '-of', 'json', path],
        capture_output=True, text=True, check=True).stdout
    d = json.loads(out)
    s = d['streams'][0]
    return int(s['width']), int(s['height']), float(d['format']['duration'])

def strip(path, t, edge, depth, w, h, across):
    """One frame's edge strip, at native resolution along the measured axis."""
    if edge in ('left', 'right'):
        x = 0 if edge == 'left' else w - depth
        vf = f'crop={depth}:{h}:{x}:0,scale={depth}:{across}:flags=area,format=gray'
        n_lines, n_perp = depth, across
    else:
        y = 0 if edge == 'top' else h - depth
        vf = f'crop={w}:{depth}:0:{y},scale={across}:{depth}:flags=area,format=gray'
        n_lines, n_perp = depth, across
    with tempfile.NamedTemporaryFile(suffix='.gray', delete=False) as f:
        tmp = f.name
    try:
        subprocess.run(['ffmpeg', '-v', 'error', '-ss', str(t), '-i', path,
                        '-frames:v', '1', '-vf', vf, '-f', 'rawvideo', tmp, '-y'],
                       check=True, capture_output=True)
        data = open(tmp, 'rb').read()
    finally:
        os.unlink(tmp)
    # Mean per line, indexed from the outer edge inward.
    if edge in ('left', 'right'):
        rows = [data[i * n_lines:(i + 1) * n_lines] for i in range(n_perp)]
        prof = [sum(r[i] for r in rows) / n_perp for i in range(n_lines)]
        if edge == 'right':
            prof.reverse()
    else:
        rows = [data[i * n_perp:(i + 1) * n_perp] for i in range(n_lines)]
        prof = [sum(r) / n_perp for r in rows]
        if edge == 'bottom':
            prof.reverse()
    return prof

def measure(path, edge, samples, depth, across, grad):
    w, h, dur = probe(path)
    limit = (w if edge in ('left', 'right') else h) // 3
    depth = min(depth, limit)
    times = [dur * i / samples for i in range(samples)]
    profs = [strip(path, t, edge, depth, w, h, across) for t in times]
    avg = [sum(p[i] for p in profs) / len(profs) for i in range(depth)]
    # Candidate boundaries, not a verdict. Each strong step inward is somewhere
    # the margin could plausibly end; which one is the composition's real edge
    # is a judgement call this cannot make -- interior art detail produces steps
    # just as large as a band edge does. Coalesce runs so one edge reports once.
    steps, last = [], -99
    for i in range(2, depth - 2):
        g = avg[i + 2] - avg[i - 2]
        if abs(g) >= grad:
            if i - last <= 4 and steps and abs(g) > abs(steps[-1][1]):
                steps[-1] = (i, g)
            elif i - last > 4:
                steps.append((i, g))
            last = i
    span = w if edge in ('left', 'right') else h
    return {'edge': edge, 'profile': avg, 'span': span, 'steps': steps}

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('video')
    ap.add_argument('--edges', default='left,right',
                    help='comma-separated edges to measure (default left,right)')
    ap.add_argument('--samples', type=int, default=8,
                    help='frames spread across the loop (default 8)')
    ap.add_argument('--depth', type=int, default=1400,
                    help='how far in from the edge to look, in native px')
    ap.add_argument('--across', type=int, default=270,
                    help='resolution along the perpendicular axis (default 270)')
    ap.add_argument('--gradient', type=float, default=8.0,
                    help='step size that counts as a margin boundary (default 8)')
    ap.add_argument('--margin', action='append', metavar='EDGE=PX',
                    help='the boundary you chose, e.g. right=256 (repeatable)')
    ap.add_argument('--write', action='store_true',
                    help='write <name>.framing.json beside the video (needs --margin)')
    a = ap.parse_args()

    chosen = {}
    for spec in a.margin or []:
        edge, _, px = spec.partition('=')
        if not px.isdigit():
            print(f'bad --margin {spec!r}; want edge=px, e.g. right=256', file=sys.stderr)
            return 2
        chosen[edge.strip()] = int(px)

    bleed = {}
    for edge in [e.strip() for e in a.edges.split(',') if e.strip()]:
        m = measure(a.video, edge, a.samples, a.depth, a.across, a.gradient)
        p, span = m['profile'], m['span']
        print(f'=== {edge} edge (span {span}px) ===')
        stepn = max(1, len(p) // 28)
        for i in range(0, min(len(p), stepn * 28), stepn):
            print(f'  {i:5d}px in: {p[i]:6.2f}')
        if m['steps']:
            print('  candidate boundaries (a margin ending here would be):')
            for i, g in m['steps']:
                px = i + 2
                print(f'    {px:5d}px = {px / span:.4f}   step {g:+7.2f}'
                      f'   {"darker" if g > 0 else "brighter"} outside')
        else:
            print('  no step found: this edge looks like continuous art')
        if edge in chosen:
            px = chosen[edge]
            bleed[edge] = round(px / span, 4)
            print(f'  -> using {px}px = {bleed[edge]:.4f} (you chose this)')
        print()

    if not chosen:
        print('Pick a boundary from the candidates and pass it back, e.g.:')
        print(f'  --margin right=256 --margin left=9 --write')
        print()
        print('How to read the profile: a flat plateau is margin, a smooth ramp')
        print('is painted art. Margin usually appears as a staircase of constant')
        print('bands, because it is the composition edge extended rather than')
        print('drawn. A step deep inside the frame is interior detail, not an')
        print('edge -- do not take the deepest candidate just because it is')
        print('listed. Confirm the geometry against the displays in use: a value')
        print('slightly too small leaves part of the band on screen, and one too')
        print('large eats composition on every display.')
        return 0

    doc = {'bleed': bleed}
    print('sidecar:')
    print(json.dumps(doc, indent=2))
    if a.write:
        out = os.path.splitext(a.video)[0] + '.framing.json'
        with open(out, 'w') as f:
            json.dump(doc, f, indent=2)
            f.write('\n')
        print(f'\nwrote {out}')
    else:
        print('\nRe-run with --write to save it beside the video.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
