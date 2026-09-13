#!/usr/bin/env python3
"""Turn one Spine lobby into an installed wallpaper, or re-render one with a new crop.

    # a lobby already extracted into the workspace, by asset id
    python3 scripts/media-batch/ingest.py hanako_home

    # a folder or ZIP of .skel/.atlas/.png, or a lobby fetched with BA-AD
    python3 scripts/media-batch/ingest.py ~/Downloads/ch0400_home.zip --title Someone
    python3 scripts/media-batch/ingest.py --fetch ch0400_home --title Someone

    # re-render an installed export so the crop box saved in its framing sidecar
    # becomes the camera (free when its textures were already upscaled)
    python3 scripts/media-batch/ingest.py --reframe ".../Hina-Restored-4K60.mp4" --from-sidecar

Every run renders a preview first and reports matte before anything slow or paid
happens; --preview stops there. Texture upscaling is the only billable step. It
runs only when the lobby has never been upscaled, is quoted from past runs first,
is capped by restore_modal.py's 15-minute timeout with no retries, and needs a
yes at the prompt or --yes. Installing over an existing export archives the old
file first, then renames the new one over it atomically, so a wallpaper playing
it never reads a half-written file and Library bookmarks resolve by path.
"""
import argparse, datetime, importlib.util, json, math, os, re, shutil, struct, subprocess, sys, tempfile, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DEFAULT_WORKSPACE = REPO / 'build/ba-export-study'
DEFAULT_OUTPUT = Path.home() / 'Pictures/Wallpapers/Blue Archive/Live2D Restored'
PLAN_SOURCE = 'Blue Archive Japan Windows assets previously retrieved using BA-AD; not publisher wallpaper downloads'
PLAN_MODEL = 'realesr-animevideov3 x4 downsampled to 2x; original alpha Lanczos'
# Modal's published list prices for what restore_modal.py asks for: one L4,
# 8 CPU cores, 16 GiB. Only used to quote; the bill is Modal's.
L4_PER_SECOND = 0.000222
CPU_CORE_PER_SECOND = 0.0000131
MEMORY_GIB_PER_SECOND = 0.00000222
CONTAINER_SECONDS = L4_PER_SECOND + 8 * CPU_CORE_PER_SECOND + 16 * MEMORY_GIB_PER_SECOND
# Image pull, weight download and model load before the first texture, measured
# loosely from past runs; the quote rounds up rather than down.
STARTUP_SECONDS = 120
TIMEOUT_SECONDS = 900


def ensure_pillow(workspace):
    """calibrate.py needs Pillow; re-run under the workspace venv when this Python lacks it."""
    try:
        import PIL  # noqa: F401
    except ImportError:
        venv = workspace / '.venv/bin/python'
        if not venv.exists() or Path(sys.executable).resolve() == venv.resolve():
            sys.exit('Pillow is required: run with the workspace venv (build/ba-export-study/.venv/bin/python).')
        os.execv(str(venv), [str(venv), __file__] + sys.argv[1:])


APP_DEFAULTS = 'com.teamleaderleo.idlesse.app'


def register_with_app(workspace):
    """Tell Idlesse where this tool lives, so its framing editor can offer a re-render.

    Only paths are recorded. The app runs --reframe without --yes, so it can never
    start a paid upscale: a lobby that still needs one stops at the quote.
    """
    # An app launched from the Finder gets a minimal PATH without Homebrew's ffmpeg
    # or a user-installed modal, so hand over the PATH this shell found them on.
    for key, value in (('IdlessePipelineInterpreter', sys.executable), ('IdlessePipelineScript', str(Path(__file__).resolve())),
                       ('IdlessePipelineWorkspace', str(workspace)), ('IdlessePipelinePath', os.environ.get('PATH', ''))):
        subprocess.run(['defaults', 'write', APP_DEFAULTS, key, '-string', value], check=False, capture_output=True)


def emit(enabled, event, **fields):
    """One machine-readable line for the app; plain logs stay human text."""
    if enabled:
        print('IDLESSE ' + json.dumps({'event': event, **fields}), flush=True)


def known_titles(workspace, output):
    """Titles already chosen for an asset: installed receipts first, then local plans."""
    titles, installed = {}, {}
    for plan in sorted(HERE.glob('plans/*.json')) + [HERE / 'batch.json']:
        try:
            for item in json.loads(plan.read_text())['items']:
                titles.setdefault(item['id'], item['title'])
        except (OSError, ValueError, KeyError):
            continue
    for receipt in output.glob('*-Restored-4K60.source.json'):
        try:
            data = json.loads(receipt.read_text())
        except ValueError:
            continue
        if data.get('asset'):
            titles[data['asset']] = data.get('title') or titles.get(data['asset'])
            installed.setdefault(data['asset'], []).append(str(receipt.with_name(receipt.name.replace('.source.json', '.mp4'))))
    return titles, installed


def list_lobbies(workspace, output):
    titles, installed = known_titles(workspace, output)
    lobbies = []
    for folder in sorted((workspace / 'assets-pc').iterdir()):
        if not folder.is_dir() or not list(folder.glob('*.skel')):
            continue
        asset = folder.name
        upscaled = restored_complete(workspace, asset)
        entry = {'asset': asset, 'title': titles.get(asset) or default_title(asset), 'installed': installed.get(asset, []),
                 'upscaled': upscaled}
        if not upscaled:
            entry['quote'] = quote(workspace, asset)
        lobbies.append(entry)
    return lobbies


def find_modal():
    found = shutil.which('modal')
    if found:
        return found
    for candidate in sorted(Path.home().glob('Library/Python/*/bin/modal'), reverse=True):
        return str(candidate)
    return None


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f'{name}.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Not a PNG: {path}')
    return struct.unpack('>II', head[16:24])


def default_title(asset):
    name = re.sub(r'_home$', '', asset)
    if re.fullmatch(r'ch\d+', name):
        return None
    return '-'.join(part.capitalize() for part in name.split('_'))


def safe_name(value):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', value):
        raise SystemExit(f'Use letters, digits, - and _ for names: {value!r}')
    return value


# --- sources -----------------------------------------------------------------

def adopt_source(source, workspace, asset_override):
    """Copy a folder or ZIP of Spine files into assets-pc/<id>; return the id."""
    source = Path(source).expanduser()
    with tempfile.TemporaryDirectory() as tmp:
        if source.suffix.lower() == '.zip':
            with zipfile.ZipFile(source) as archive:
                for member in archive.namelist():
                    if member.startswith('/') or '..' in Path(member).parts:
                        raise SystemExit(f'Refusing unsafe ZIP entry: {member}')
                archive.extractall(tmp)
            root = Path(tmp)
        else:
            root = source
        skels = sorted(p for p in root.rglob('*.skel') if not p.name.startswith('._'))
        if not skels:
            raise SystemExit(f'No .skel file in {source}')
        folder = skels[0].parent
        asset = safe_name(asset_override or folder.name if folder != Path(tmp) else asset_override or skels[0].stem.lower())
        dest = workspace / 'assets-pc' / asset
        files = [p for p in folder.iterdir() if p.suffix.lower() in ('.skel', '.atlas', '.png') and not p.name.startswith('._')]
        if dest.exists():
            same = {p.name for p in dest.iterdir()} == {p.name for p in files} and all(
                (dest / p.name).read_bytes() == p.read_bytes() for p in files)
            if not same:
                raise SystemExit(f'{dest} already holds different files; pass --asset to choose a new id.')
            return asset
        dest.mkdir(parents=True)
        for path in files:
            shutil.copy2(path, dest / path.name)
        print(f'Copied {len(files)} files into {dest}')
        return asset


def fetch(asset, workspace):
    """Download one lobby's Windows bundles with BA-AD and extract its Spine files."""
    baad = workspace / 'baad/baad'
    if not baad.exists():
        raise SystemExit(f'No BA-AD binary at {baad}')
    bundles = workspace / 'newer-windows'
    print(f'Fetching {asset} with BA-AD (Japan, Windows); this downloads only that lobby.', flush=True)
    subprocess.run([str(baad), 'download', 'japan', '--assets', '--platform', 'windows',
                    '--filter', f'spinelobbies-{asset}-', '--output', str(bundles)], cwd=workspace, check=True)
    python = workspace / '.venv/bin/python'
    subprocess.run([str(python), 'extract.py', asset], cwd=workspace, check=True)
    if not list((workspace / 'assets-pc' / asset).glob('*.skel')):
        raise SystemExit(f'BA-AD found nothing for {asset}; check the id against the game files.')


def stem_of(workspace, asset):
    skels = sorted((workspace / 'assets-pc' / asset).glob('*.skel'))
    main = [p for p in skels if p.stem.lower().endswith('_home')] or skels
    if not main:
        raise SystemExit(f'No skeleton in assets-pc/{asset}')
    return main[0].stem


# --- camera ------------------------------------------------------------------

def crop_to_camera(base, crop):
    """Camera that frames `crop`, a unit box of the frame `base` renders.

    The renderer maps a stage point p to 0.5 + (p - c) * zoom in frame units, so
    a point at q in the current frame sits at p = c + (q - 0.5) / zoom. Centre the
    box there and scale so its longer side (relative to the 16:9 frame) fills it:
    a box that is not 16:9 is shown whole, with a little extra around it.
    """
    zoom, cx, cy = base or [1.0, 0.5, 0.5]
    x, y, w, h = crop
    if not (0 <= x < 1 and 0 <= y < 1 and 0 < w <= 1 and 0 < h <= 1 and x + w <= 1.0001 and y + h <= 1.0001):
        raise SystemExit(f'Crop must be a unit box inside the frame: {crop}')
    return [round(zoom / max(w, h), 4), round(cx + (x + w / 2 - 0.5) / zoom, 4), round(cy + (y + h / 2 - 0.5) / zoom, 4)]


def recipe_for(cameras, stem, animation):
    entry = cameras.get(stem)
    if isinstance(entry, dict):
        return entry.get(animation) or entry.get('default')
    return entry


def with_recipe(cameras, stem, animation, camera):
    """Set a recipe for one animation without changing what the others use."""
    result = dict(cameras)
    entry = result.get(stem)
    if isinstance(entry, dict):
        result[stem] = {**entry, animation: camera}
    elif isinstance(entry, list) and entry != camera:
        result[stem] = {'default': entry, animation: camera}
    else:
        result[stem] = camera
    return result


def write_cameras(path, cameras):
    path.write_text(json.dumps(cameras, indent=2) + '\n')


# --- restoration -------------------------------------------------------------

def restored_complete(workspace, asset):
    source = workspace / 'assets-pc' / asset
    restored = workspace / 'assets-ai-batch' / asset
    if not restored.is_dir():
        return False
    for png in source.glob('*.png'):
        copy = restored / png.name
        if not copy.exists():
            return False
        w, h = png_size(png)
        if png_size(copy) != (w * 2, h * 2):
            return False
    return all((restored / p.name).exists() for p in source.iterdir() if p.suffix in ('.skel', '.atlas'))


def past_rate(workspace):
    """Seconds of GPU per source megapixel, from every past restoration report."""
    seconds = megapixels = 0.0
    for report in workspace.glob('*/restored.zip.json'):
        try:
            data = json.loads(report.read_text())
            for texture in data['textures']:
                seconds += texture['seconds']
                megapixels += texture['size'][0] * texture['size'][1] / 4 / 1e6
        except (ValueError, KeyError, TypeError):
            continue
    return seconds / megapixels if megapixels else 1.5


def quote(workspace, asset):
    pngs = sorted((workspace / 'assets-pc' / asset).glob('*.png'))
    megapixels = sum(math.prod(png_size(p)) for p in pngs) / 1e6
    work = megapixels * past_rate(workspace)
    estimate = STARTUP_SECONDS + work
    return {'textures': len(pngs), 'megapixels': round(megapixels, 1), 'gpuSeconds': round(work),
            'estimateSeconds': round(estimate), 'estimateUSD': estimate * CONTAINER_SECONDS,
            'capUSD': TIMEOUT_SECONDS * CONTAINER_SECONDS}


def confirm_paid(workspace, asset, yes):
    q = quote(workspace, asset)
    print(f'\nUpscaling {asset} needs one Modal L4 job: {q["textures"]} texture(s), {q["megapixels"]} MP.')
    print(f'  Estimate ~{q["estimateSeconds"]}s of container time (~{q["gpuSeconds"]}s on the GPU), about ${q["estimateUSD"]:.2f}.')
    print(f'  Hard cap: {TIMEOUT_SECONDS // 60} minutes, one container, no retries, so at most about ${q["capUSD"]:.2f}.')
    print('  Estimate uses list prices and your past runs; Modal bills the actual time.')
    if yes:
        print('  --yes given; starting.')
        return
    if not sys.stdin.isatty():
        raise SystemExit('Not starting a paid job without confirmation: rerun with --yes.')
    if input('Start it? [y/N] ').strip().lower() not in ('y', 'yes'):
        raise SystemExit('Stopped before anything was billed.')


def prepare_free_restore(workspace, asset, job):
    """run.py only calls Modal when the job lacks restored.zip; build it from textures we already have."""
    with zipfile.ZipFile(job / 'restored.zip', 'w', zipfile.ZIP_STORED) as archive:
        for png in sorted((workspace / 'assets-pc' / asset).glob('*.png')):
            archive.write(workspace / 'assets-ai-batch' / asset / png.name, f'{asset}/{png.name}')


# --- install -----------------------------------------------------------------

def install(staged_dir, title, output, replace, clear_framing, log):
    output.mkdir(parents=True, exist_ok=True)
    video = f'{title}-Restored-4K60.mp4'
    final = output / video
    stamp = datetime.date.today().isoformat()
    if final.exists():
        if not replace:
            raise SystemExit(f'{final} exists; pass --replace to archive it and install over it.')
        archive = output / f'superseded-{stamp}'
        archive.mkdir(exist_ok=True)
        for name in (video, f'{title}.jpg', f'{title}-Restored-4K60.source.json', f'{title}-Restored-4K60.framing.json'):
            if (output / name).exists() and not (archive / name).exists():
                shutil.copy2(output / name, archive / name)
        log(f'Archived the previous export in {archive}')
    for name in (video, f'{title}.jpg', f'{title}-Restored-4K60.source.json'):
        # Copy beside the target, then rename over it. The rename is atomic, so a
        # wallpaper playing the old file keeps reading the old inode until it
        # reloads, instead of decoding a file being truncated and rewritten under
        # it. Library bookmarks resolve by path, so a new inode is found.
        partial = output / f'.{name}.partial'
        shutil.copyfile(staged_dir / name, partial)
        os.replace(partial, output / name)
    sidecar = output / f'{title}-Restored-4K60.framing.json'
    if clear_framing and sidecar.exists():
        data = json.loads(sidecar.read_text())
        dropped = [k for k in ('bleed', 'focus') if data.pop(k, None) is not None]
        if dropped:
            if data:
                sidecar.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
            else:
                sidecar.unlink()
            log(f'The new camera replaces the sidecar {" and ".join(dropped)}; kept {sorted(data) or "nothing else"}.')
    return final


# --- main --------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('source', nargs='?', help='Asset id in assets-pc, or a folder or ZIP of Spine files')
    p.add_argument('--fetch', metavar='ASSET', help='Download this lobby with BA-AD first')
    p.add_argument('--reframe', type=Path, metavar='MEDIA', help='Re-render an installed export')
    p.add_argument('--asset', help='Id to store a folder or ZIP under (default: its folder name)')
    p.add_argument('--title', help='Name of the installed file, e.g. Hoshino-Swimsuit')
    p.add_argument('--animation', default='Idle_01')
    p.add_argument('--crop', type=float, nargs=4, metavar=('X', 'Y', 'W', 'H'),
                   help='Unit box of the current frame to keep, from its top-left')
    p.add_argument('--camera', type=float, nargs=3, metavar=('ZOOM', 'CX', 'CY'), help='Use this camera recipe (before --crop)')
    p.add_argument('--fit', action='store_true', help='Zoom and recentre the camera until the preview shows no matte')
    p.add_argument('--from-sidecar', action='store_true', help='With --reframe, use the crop box saved by the framing editor')
    p.add_argument('--preview', action='store_true', help='Render and measure the preview, then stop')
    p.add_argument('--allow-matte', action='store_true', help='Export even if the preview shows matte')
    p.add_argument('--replace', action='store_true', help='Archive and replace an existing export of the same title')
    p.add_argument('--yes', action='store_true', help='Start a quoted paid upscale without prompting')
    p.add_argument('--workspace', type=Path, default=DEFAULT_WORKSPACE)
    p.add_argument('--output', type=Path, help=f'Install folder (default: {DEFAULT_OUTPUT}, or the reframed file\'s folder)')
    p.add_argument('--list', action='store_true', help='Print every extracted lobby as JSON, with install and upscale state')
    p.add_argument('--json', action='store_true', help='Also print IDLESSE-prefixed JSON events, for the app')
    a = p.parse_args()
    workspace = a.workspace.expanduser().resolve()
    ensure_pillow(workspace)
    calibrate = load('calibrate')
    register_with_app(workspace)
    log = lambda message: print(message, flush=True)
    if a.list:
        print(json.dumps(list_lobbies(workspace, (a.output or DEFAULT_OUTPUT).expanduser().resolve()), indent=2))
        return

    receipt = None
    if a.reframe:
        media = a.reframe.expanduser().resolve()
        receipt_path = media.with_suffix('.source.json')
        if not receipt_path.exists():
            raise SystemExit(f'No {receipt_path.name} beside it; only pipeline exports can be re-rendered.')
        receipt = json.loads(receipt_path.read_text())
        asset, animation = receipt['asset'], receipt['animation']
        title = a.title or receipt.get('title') or re.sub(r'-Restored-4K60$', '', media.stem)
        if media.name != f'{title}-Restored-4K60.mp4':
            raise SystemExit(f'Expected {title}-Restored-4K60.mp4, got {media.name}; pass --title.')
        output = (a.output or media.parent).expanduser().resolve()
        a.replace = True
        if a.from_sidecar:
            sidecar = media.with_name(media.stem + '.framing.json')
            bleed = json.loads(sidecar.read_text()).get('bleed') if sidecar.exists() else None
            if not bleed:
                raise SystemExit('The sidecar has no crop box to use; draw one in Adjust Framing… first.')
            left, top = bleed.get('left', 0), bleed.get('top', 0)
            a.crop = [left, top, 1 - left - bleed.get('right', 0), 1 - top - bleed.get('bottom', 0)]
        if not a.crop:
            raise SystemExit('--reframe needs --crop or --from-sidecar.')
    else:
        if a.fetch:
            asset = safe_name(a.fetch)
            if not (workspace / 'assets-pc' / asset).exists():
                fetch(asset, workspace)
        elif not a.source:
            p.error('give an asset id, a folder or ZIP, --fetch, or --reframe')
        elif (workspace / 'assets-pc' / a.source).is_dir() and '/' not in a.source:
            asset = a.source
        else:
            asset = adopt_source(a.source, workspace, a.asset)
        animation = a.animation
        title = a.title or default_title(asset)
        if not title and not a.preview:
            raise SystemExit(f'{asset} has no readable name; pass --title.')
        output = (a.output or DEFAULT_OUTPUT).expanduser().resolve()
    title = safe_name(title) if title else None
    stem = stem_of(workspace, asset)

    # Camera: the recipe the installed export was rendered with when re-framing,
    # otherwise whatever the workspace would use, then the crop applied on top.
    cameras_path = workspace / 'cameras.json'
    cameras = json.loads(cameras_path.read_text()) if cameras_path.exists() else {}
    base = (receipt or {}).get('camera') or recipe_for(cameras, stem, animation)
    if a.camera:
        base = [round(v, 4) for v in a.camera]
    camera = crop_to_camera(base, a.crop) if a.crop else base
    original_cameras = cameras_path.read_text() if cameras_path.exists() else None
    changed = camera is not None and camera != recipe_for(cameras, stem, animation)
    job = workspace / f'ingest-{asset}-{datetime.datetime.now():%Y%m%d-%H%M%S}'
    keep_camera = False
    server = calibrate.serve(workspace)
    try:
        def use_camera(recipe):
            write_cameras(cameras_path, with_recipe(cameras, stem, animation, recipe))
            calibrate.rebundle(workspace)
        if changed:
            use_camera(camera)
            log(f'Camera for {stem}/{animation}: {base or "fit"} -> {camera}')

        # Preview from the original textures: same skeleton, same framing, and free.
        preview_args = argparse.Namespace(asset=f'assets-pc/{asset}', stem=stem, animation=animation, seconds=0.0)
        edges, image, duration = calibrate.worst_edges(workspace, server, preview_args, 1920, 1080, 4)
        if a.fit and duration:
            for round_ in range(8):
                if calibrate.clean(edges):
                    break
                camera = calibrate.next_camera(camera or [1.0, 0.5, 0.5], edges)
                use_camera(camera)
                changed = True
                edges, image, duration = calibrate.worst_edges(workspace, server, preview_args, 1920, 1080, 4)
                log(f'  fit round {round_ + 1}: {camera} -> worst matte {edges["_native"]}px')
        previews = workspace / 'ingest-previews'
        previews.mkdir(exist_ok=True)
        preview = previews / f'{asset}-{animation}.png'
        image.save(preview)
        if not duration:
            meta_animations = []
            with tempfile.TemporaryDirectory() as tmp:
                _, meta = calibrate.render(workspace, server, f'assets-pc/{asset}', stem, animation, Path(tmp) / 'm', 64, 36, 0)
                meta_animations = [x['name'] for x in meta.get('animations', [])]
            raise SystemExit(f'{stem} has no animation {animation!r}; it has {meta_animations}.')
        matte = edges['_native']
        log(f'Preview {preview}')
        log(f'  {animation}: {duration:.3f}s loop; worst matte over the loop {matte}px '
            + ('(clean)' if calibrate.clean(edges) else '(MATTE: the camera leaves part of the frame uncovered)'))
        free = restored_complete(workspace, asset)
        emit(a.json, 'preview', asset=asset, title=title, animation=animation, image=str(preview), seconds=duration,
             matte=matte, clean=calibrate.clean(edges), camera=camera, upscaled=free,
             quote=None if free else quote(workspace, asset), replaces=str(output / f'{title}-Restored-4K60.mp4')
             if title and (output / f'{title}-Restored-4K60.mp4').exists() else None)
        if a.preview:
            log('Preview only: nothing exported, camera left as it was.')
            return
        # Before anything slow or paid: an existing wallpaper is only replaced on request.
        if (output / f'{title}-Restored-4K60.mp4').exists() and not a.replace:
            raise SystemExit(f'{title}-Restored-4K60.mp4 already exists in {output}; pass --replace to archive it and install over it.')
        if not calibrate.clean(edges) and not a.allow_matte:
            raise SystemExit('Stopping before export because the preview shows matte; adjust the crop or pass --allow-matte.')

        job.mkdir()
        if free:
            prepare_free_restore(workspace, asset, job)
            modal = '/usr/bin/false'
            log('Textures were upscaled before; this export is local and free.')
        else:
            modal = find_modal()
            if not modal:
                raise SystemExit('This lobby needs upscaling, and the modal CLI is not installed.')
            confirm_paid(workspace, asset, a.yes)

        plan = job / 'plan.json'
        plan.write_text(json.dumps({'schema': 1, 'model': PLAN_MODEL, 'source': PLAN_SOURCE, 'items': [
            {'id': asset, 'title': title, 'stem': stem, 'animation': animation, 'seconds': duration}]}, indent=2))
        staged = job / 'out'
        subprocess.run([sys.executable if Path(sys.executable).exists() else 'python3', str(HERE / 'run.py'),
                        '--root', str(workspace), '--output', str(staged), '--plan', str(plan),
                        '--job-name', job.name, '--port', '0', '--modal', modal], check=True)
        keep_camera = True
        final = install(staged, title, output, a.replace, clear_framing=changed, log=log)
        if changed:
            tracked = HERE / 'cameras.json'
            write_cameras(tracked, with_recipe(json.loads(tracked.read_text()), stem, animation, camera))
            log(f'Recorded the camera in {tracked.relative_to(REPO)}; commit it to keep the recipe.')
        log(f'\nInstalled {final}')
        emit(a.json, 'installed', path=str(final), camera=camera)
        log('A Library source watching that folder picks it up; otherwise Import… it once. '
            'If it is on the desktop now, it reloads the next time it is chosen.')
    finally:
        server.shutdown(); server.server_close()
        if changed and not keep_camera:
            if original_cameras is None:
                cameras_path.unlink(missing_ok=True)
            else:
                cameras_path.write_text(original_cameras)
            calibrate.rebundle(workspace)


if __name__ == '__main__':
    main()
