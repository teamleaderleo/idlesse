#!/usr/bin/env python3
"""Lossless-frame x265 10-bit export with a loopback-only frame receiver.

The page renders each frame, reads its pixels and POSTs them here; they go
straight into FFmpeg's stdin as raw RGBA. x265 is the slow stage, so a POST is
answered only once the encoder has taken the frame, and the page waits for it.
"""
import argparse, json, os, secrets, subprocess, threading
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

# x265's lookahead runs on one thread by default and starves the frame threads;
# spreading it over threads and slices roughly doubled throughput on a 10-core
# M-series. Two frame threads and a short lookahead keep one encoder near 2 GB.
X265_PARAMS = 'log-level=error:aq-mode=3:lookahead-threads=3:rc-lookahead=10:lookahead-slices=8:frame-threads=2'


def main():
    p = argparse.ArgumentParser()
    for name in ('output', 'count', 'width', 'height', 'folder', 'stem', 'animation'):
        p.add_argument(name, type={'output': Path, 'count': int, 'width': int, 'height': int}.get(name, str))
    a = p.parse_args()
    if not 1 <= a.count <= 5400 or (a.width, a.height) != (3840, 2160):
        p.error('Export exceeds the 4K/90-second budget')
    root = Path.cwd()
    dest = a.output.resolve()
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        p.error('Output already exists')
    partial_path = dest.with_name(dest.stem + '.partial.mp4')
    frame_bytes = a.width * a.height * 4
    token = secrets.token_hex(24)
    ffmpeg = subprocess.Popen([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', f'{a.width}x{a.height}', '-framerate', '60', '-i', 'pipe:0', '-an',
        # readPixels rows start at the bottom.
        '-vf', 'vflip,scale=out_color_matrix=bt709:out_range=full,format=yuv420p10le',
        '-c:v', 'libx265', '-preset', 'fast', '-b:v', '40M', '-maxrate', '60M', '-bufsize', '80M', '-x265-params', X265_PARAMS,
        '-color_range', 'pc', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'iec61966-2-1',
        '-tag:v', 'hvc1', '-movflags', '+faststart+write_colr', str(partial_path)], stdin=subprocess.PIPE)
    state = {'next': 0}
    lock = threading.Lock()

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def handle(self):
            try:
                super().handle()
            except (ConnectionResetError, BrokenPipeError):
                pass

        def do_POST(self):
            prefix = f'/{token}/'
            try:
                n = int(self.headers.get('Content-Length', '0'))
                index = int(self.path[len(prefix):]) if self.path.startswith(prefix) else -1
            except ValueError:
                self.send_error(400)
                return
            if self.headers.get('Origin') not in (None, f'http://127.0.0.1:{self.server.server_port}'):
                self.send_error(403)
                return
            with lock:
                if n != frame_bytes or index != state['next'] or index >= a.count:
                    self.send_error(400)
                    return
                self.connection.settimeout(120)
                remaining = n
                while remaining:
                    chunk = self.rfile.read(min(remaining, 8 * 1024 * 1024))
                    if not chunk:
                        raise IOError('Incomplete frame')
                    ffmpeg.stdin.write(chunk)
                    remaining -= len(chunk)
                state['next'] += 1
            self.send_response(200)
            self.send_header('Content-Length', '0')
            self.end_headers()

    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    code = dest.with_suffix('.encode.js')
    meta = Path(str(dest) + '.json')
    code.write_text('return await window.rawExport(' + ','.join(json.dumps(v) for v in
                    [a.folder, a.stem, a.animation, a.count, a.width, a.height, f'/{token}']) + ');')
    try:
        subprocess.run([str(root / 'encode'), f'http://127.0.0.1:{server.server_port}/index.html', str(code), str(meta)],
                       check=True, timeout=1850)
        if state['next'] != a.count:
            raise RuntimeError(f'Encoder received {state["next"]} of {a.count} frames')
        ffmpeg.stdin.close()
        if ffmpeg.wait(timeout=600) != 0:
            raise RuntimeError('x265 did not finish cleanly')
        result = json.loads(meta.read_text())
        if result['frames'] != a.count:
            raise RuntimeError('Incomplete encoder receipt')
        partial_path.replace(dest)
        print('Encoded', a.count, 'frames with x265 in', round(result['encodeSeconds'], 1), 'seconds', flush=True)
    finally:
        if ffmpeg.poll() is None:
            ffmpeg.kill()
        server.shutdown()
        server.server_close()
        code.unlink(missing_ok=True)
        partial_path.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
