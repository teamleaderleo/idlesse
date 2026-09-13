#!/usr/bin/env python3
"""Resume a texture-restoration/export batch. No application preferences are edited."""
import argparse, contextlib, os, sys, fcntl, hashlib, json, re, shutil, subprocess, threading, time, zipfile
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def save(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def scale_atlas(text):
    return '\n'.join(re.sub(r'-?\d+', lambda m: str(int(m[0]) * 2), line)
                     if re.match(r'\s*(size|xy|orig|offset|bounds|offsets):', line) else line
                     for line in text.splitlines()) + '\n'


def run(argv, log, cwd=None, timeout=1200, env=None, progress=None):
    """Run to completion into `log`. With `progress`, also echo the renderer's
    frame count as it goes, so a ten-minute x265 export is not a silent one."""
    with log.open('ab') as stream:
        if progress is None:
            subprocess.run(argv, cwd=cwd, stdout=stream, stderr=stream, check=True, timeout=timeout, env=env)
            return
        process = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        expired = threading.Event()
        timer = threading.Timer(timeout, lambda: (expired.set(), process.kill()))
        timer.start()
        try:
            for line in process.stdout:
                stream.write(line)
                match = re.match(rb'Frame (\d+)', line)
                if match and int(match.group(1)) % 60 == 0:
                    print(progress(int(match.group(1))), flush=True)
        finally:
            timer.cancel()
        if process.wait() != 0:
            if expired.is_set():
                raise subprocess.TimeoutExpired(argv, timeout)
            raise subprocess.CalledProcessError(process.returncode, argv)


@contextlib.contextmanager
def encoder_slot(root, x265):
    """Hardware encodes take the workspace's one lock. x265 exports are CPU work
    that one job cannot saturate, so IDLESSE_X265_JOBS (default 3) may run at once."""
    if not x265:
        with (root / '.media-encoder.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield 0
        return
    slots = max(1, int(os.environ.get('IDLESSE_X265_JOBS', '3')))
    while True:
        for slot in range(slots):
            lock = (root / f'.media-encoder-x265-{slot}.lock').open('a')
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                lock.close()
                continue
            try:
                yield slot
            finally:
                lock.close()
            return
        time.sleep(2)


def probe(path):
    result = json.loads(subprocess.check_output(['ffprobe', '-v', 'error',
        '-select_streams', 'v:0', '-show_entries', 'stream=codec_name,width,height,r_frame_rate,color_space,color_transfer,color_primaries',
        '-show_entries', 'format=duration,size', '-of', 'json', str(path)]))
    decoded = subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-nostats',
        '-hwaccel', 'videotoolbox', '-i', str(path), '-map', '0:v:0', '-an',
        '-fps_mode', 'passthrough', '-f', 'null', '-progress', 'pipe:1', '-'],
        capture_output=True, text=True, check=True, timeout=300)
    fields = dict(line.split('=', 1) for line in decoded.stdout.splitlines() if '=' in line)
    if fields.get('progress') != 'end' or int(fields.get('drop_frames', '0')):
        raise RuntimeError('Incomplete verification decode: ' + str(path))
    result['streams'][0]['nb_read_frames'] = fields['frame']
    result['verification'] = 'complete VideoToolbox decode with passthrough timestamps'
    return result


def normalize_colour(path, log):
    """Record how the pixels are encoded, without re-encoding them.

    Both encoders leave colour metadata to chance. The frame encoder's FFmpeg
    call set none at all, and WebCodecs tagged some exports fully and others
    with no transfer function. macOS reads a missing transfer as video gamma and
    lifts midtones about ten levels, so 38 of 96 lobby exports showed washed
    out and desaturated against their own renders -- Hina's median rendered at
    74 and displayed at 84, Shiroko's at 143 and 154. Rewriting the tags alone
    made both display exactly as rendered.

    The renderer draws sRGB, so transfer and primaries are always sRGB/BT.709.
    Range and any matrix the stream declares are kept; an undeclared matrix is
    BT.601, FFmpeg's default RGB conversion, which matched both untagged
    families on saturation where BT.709 overshot.
    """
    tags = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=color_range,color_space,color_transfer,color_primaries', '-of', 'json', str(path)]))['streams'][0]
    colour_range = tags.get('color_range') if tags.get('color_range') in ('tv', 'pc') else 'tv'
    matrix = tags.get('color_space') if tags.get('color_space') in ('bt709', 'smpte170m') else 'smpte170m'
    if (tags.get('color_transfer'), tags.get('color_primaries'), tags.get('color_space'), tags.get('color_range')) == ('iec61966-2-1', 'bt709', matrix, colour_range):
        return False
    codes = {'bt709': 1, 'smpte170m': 6}
    retagged = path.with_name(path.stem + '.colour' + path.suffix)
    run(['ffmpeg', '-v', 'error', '-y', '-i', str(path), '-map', '0', '-c', 'copy',
         '-bsf:v', f"hevc_metadata=colour_primaries=1:transfer_characteristics=13:matrix_coefficients={codes[matrix]}:video_full_range_flag={int(colour_range == 'pc')}",
         '-color_primaries', 'bt709', '-color_trc', 'iec61966-2-1', '-colorspace', matrix, '-color_range', colour_range,
         '-tag:v', 'hvc1', '-movflags', '+faststart+write_colr', str(retagged)], log)
    retagged.replace(path)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True, help='Prepared Spine render workspace')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--plan', type=Path, default=Path(__file__).with_name('batch.json'))
    parser.add_argument('--modal', default=shutil.which('modal'))
    parser.add_argument('--job-name', default='batch-2026-09-10')
    parser.add_argument('--port', type=int, default=18763)
    parser.add_argument('--frame-asset', action='append', default=[])
    parser.add_argument('--encoder', choices=['webcodecs','frames','x265'], default='webcodecs',
        help='x265 sends lossless frames to 10-bit HEVC: slower, without gradient banding; several can run at once')
    parser.add_argument('--restore-only', action='store_true', help='Prepare textures without starting the local renderer')
    args = parser.parse_args()
    if Path(args.job_name).name != args.job_name or args.job_name in ('', '.', '..'):
        parser.error('job-name must be a simple directory name')
    if args.port != 0 and not 1024 <= args.port <= 65535: parser.error('Invalid local port')
    root, output = args.root.resolve(), args.output.resolve()
    plan = json.loads(args.plan.read_text())
    if set(args.frame_asset) - {i['id'] for i in plan['items']}: parser.error('Unknown frame-asset')
    job = root / args.job_name; job.mkdir(exist_ok=True)
    lock = (job / 'lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    output.mkdir(parents=True, exist_ok=True)
    fingerprint = hashlib.sha256(args.plan.read_bytes())
    for item in plan['items']:
        for path in sorted((root / 'assets-pc' / item['id']).iterdir()):
            fingerprint.update(path.name.encode()); fingerprint.update(digest(path).encode())
    identity = fingerprint.hexdigest()
    state_path = job / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {'identity': identity, 'items': {}}
    if state['identity'] != identity:
        raise RuntimeError('Inputs changed: use a new batch workspace; refusing stale checkpoint')
    state['total'] = len(plan['items']); state['plan'] = str(args.plan.resolve()); state['ownerPID'] = os.getpid()
    save(state_path, state)
    source_zip, restored_zip = job / 'input.zip', job / 'restored.zip'
    if not state.get('restored'):
        with zipfile.ZipFile(source_zip, 'w', zipfile.ZIP_STORED) as archive:
            for item in plan['items']:
                for path in sorted((root / 'assets-pc' / item['id']).glob('*.png')):
                    archive.write(path, item['id'] + '/' + path.name)
        if not restored_zip.exists():
            print('Restoring texture sheets in one bounded L4 job', flush=True)
            run([args.modal, 'run', str(Path(__file__).with_name('restore_modal.py')), '--input-path',
                 str(source_zip), '--output-path', str(restored_zip)], job / 'gpu.log')
        restored = root / 'assets-ai-batch'
        with zipfile.ZipFile(restored_zip) as archive:
            expected = {i['id'] + '/' + p.name for i in plan['items']
                        for p in (root / 'assets-pc' / i['id']).glob('*.png')}
            if set(archive.namelist()) != expected:
                raise RuntimeError('Unexpected restored texture manifest')
            archive.extractall(restored)
        for item in plan['items']:
            dest = restored / item['id']
            for path in (root / 'assets-pc' / item['id']).iterdir():
                if path.suffix == '.atlas':
                    (dest / path.name).write_text(scale_atlas(path.read_text()))
                elif path.suffix != '.png':
                    shutil.copy2(path, dest / path.name)
        state['restored'] = True; save(state_path, state)
    if args.restore_only:
        print('Restored textures verified; export remains pending', flush=True)
        return
    class QuietHandler(SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
    handler = partial(QuietHandler, directory=str(root))
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for item in plan['items']:
            title = item['title']; final = output / (title + '-Restored-4K60.mp4')
            prior = state['items'].get(item['id'])
            if prior and final.exists() and digest(final) == prior['sha256']:
                print('Verified checkpoint:', title, flush=True); continue
            if final.exists():
                raise RuntimeError('Untracked or changed output: ' + str(final))
            temporary = job / (title + '.mp4')
            start = time.monotonic(); frames = round(item['seconds'] * 60)
            print('Rendering', title, frames, 'frames', flush=True)
            if temporary.exists():
                try:
                    recovered = probe(temporary)['streams'][0]
                    if (recovered['width'], recovered['height'], recovered['r_frame_rate'], int(recovered['nb_read_frames'])) != (3840, 2160, '60/1', frames):
                        temporary.unlink()
                except (subprocess.CalledProcessError, KeyError, IndexError, ValueError):
                    temporary.unlink(missing_ok=True)
            reused = temporary.exists()
            if not reused:
                frame_args = [str(temporary), str(frames), '3840', '2160',
                    'assets-ai-batch/' + item['id'], item['stem'], item['animation']]
                use_frames = args.encoder == 'frames' or item['id'] in args.frame_asset
                x265 = args.encoder == 'x265' and not use_frames
                helper = 'encode_x265.py' if x265 else 'encode.py'
                renderer = [str(root / 'render')] if use_frames else [sys.executable, str(Path(__file__).with_name(helper))]
                state['current'] = {'asset': item['id'], 'title': title, 'stage': 'waiting-for-encoder'}; save(state_path, state)
                with encoder_slot(root, x265) as slot:
                    state['current']['stage'] = 'encoding'; save(state_path, state)
                    try:
                        run(renderer + frame_args, job / (title + '.log'), root, 1900,
                            progress=lambda done: f'Rendered {done} of {frames} frames',
                            env={**os.environ, 'IDLESSE_RENDER_PORT': str(server.server_port)})
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                        if use_frames or x265: raise
                        print('WebCodecs failed; using frame encoder once:', title, flush=True)
                        temporary.unlink(missing_ok=True)
                        Path(str(temporary) + '.json').unlink(missing_ok=True)
                        run([str(root / 'render')] + frame_args, job / (title + '.log'), root, 1900,
                            env={**os.environ, 'IDLESSE_RENDER_PORT': str(server.server_port)})
            normalize_colour(temporary, job / (title + '.log'))
            result = probe(temporary); v = result['streams'][0]
            if (v['width'], v['height'], v['r_frame_rate'], int(v['nb_read_frames'])) != (3840, 2160, '60/1', frames):
                raise RuntimeError('Invalid encoded stream: ' + title)
            render_meta = json.loads(Path(str(temporary) + '.json').read_text())
            duration = next(a['duration'] for a in render_meta['animations'] if a['name'] == item['animation'])
            background_durations = [a['duration'] for a in render_meta.get('backgroundAnimations', []) if a['name'] == item['animation']]
            if any(round(d * 60) > 0 and frames % round(d * 60) for d in [duration] + background_durations):
                raise RuntimeError('Plan does not cover complete authored loops: ' + title)
            poster = output / (title + '.jpg')
            run(['ffmpeg', '-v', 'error', '-y', '-ss', '2', '-i', str(temporary), '-frames:v', '1',
                 '-vf', 'scale=1024:-2', '-q:v', '3', str(poster)], job / (title + '.log'))
            shutil.move(temporary, final)
            receipt = {'title': title, 'path': str(final), 'sha256': digest(final), 'probe': result,
                'attemptSeconds': round(time.monotonic() - start, 2), 'reusedEncodedVideo': reused, 'source': plan['source'],
                'restoration': plan['model'], 'encoder': 'x265-main10' if args.encoder == 'x265' and item['id'] not in args.frame_asset else 'webcodecs' if 'encodeSeconds' in render_meta else 'frames', 'encoderSeconds': render_meta.get('encodeSeconds'), 'rendererSHA256': digest(root/'render.bundle.js'), 'asset': item['id'], 'animation': item['animation'], 'camera': render_meta.get('camera'),
                'caveat': 'Upscaled texture detail; Spine-only rendering may omit Unity effects/physics. Visual QA required.'}
            save(final.with_suffix('.source.json'), receipt)
            state['items'][item['id']] = receipt; state.pop('current', None); save(state_path, state)
            print('Completed', title, receipt['attemptSeconds'], 'seconds', flush=True)
        state['phase'] = 'exports-verified-awaiting-visual-review-and-import'; save(state_path, state)
    finally:
        server.shutdown(); server.server_close()

if __name__ == '__main__':
    main()
