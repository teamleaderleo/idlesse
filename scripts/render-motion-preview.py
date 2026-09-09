#!/usr/bin/env python3
"""Render a bounded, offline scene-time preview; this is not an FPS benchmark."""
import argparse
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("scene", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--duration", type=float, default=4)
parser.add_argument("--fps", type=int, default=12)
parser.add_argument("--keep-stills", action="store_true")
parser.add_argument("--app", type=Path, help="Optional Idlesse executable from an isolated build")
args = parser.parse_args()
if not math.isfinite(args.duration) or not 0.1 <= args.duration <= 15 or not 1 <= args.fps <= 30:
    parser.error("Use duration 0.1–15 seconds and 1–30 fps.")
count = math.ceil(args.duration * args.fps)
if count > 180:
    parser.error("A preview supports at most 180 frames.")
repo = Path(__file__).resolve().parent.parent
app = args.app.resolve() if args.app else repo / "build/Idlesse.app/Contents/MacOS/Idlesse"
ffmpeg = shutil.which("ffmpeg")
if not app.is_file() or not ffmpeg:
    parser.error("Build Idlesse.app and install ffmpeg first.")
scene = args.scene.resolve(strict=True)
output = args.output.resolve()
indices = sorted({0, count // 2, count - 1}) if args.keep_stills else []
stills = {i: output.with_name(f"{output.stem}-{i:03d}.png") for i in indices}
if output.suffix.lower() != ".mp4" or not output.parent.is_dir():
    parser.error("Choose an .mp4 output in an existing directory.")
if any(path.exists() for path in [output, *stills.values()]):
    parser.error("Output already exists; choose another name.")

def publish(source, destination):
    # Exclusive creation also protects files created after the initial check.
    with destination.open("xb") as target, source.open("rb") as original:
        shutil.copyfileobj(original, target)

with tempfile.TemporaryDirectory(prefix="motion-preview-", dir=repo / "build") as directory:
    frames = Path(directory)
    for index in range(count):
        result = subprocess.run([str(app), "--render-scene", str(scene),
            str(frames / f"{index:03d}.png"), str(index / args.fps)],
            cwd=repo, capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise SystemExit(result.stderr.strip() or "Scene rendering failed.")
    movie = frames / "preview.mp4"
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-n",
        "-framerate", str(args.fps), "-i", str(frames / "%03d.png"),
        "-an", "-c:v", "libx264", "-crf", "22", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", str(movie)], check=True, timeout=120)
    publish(movie, output)
    for index, destination in stills.items():
        publish(frames / f"{index:03d}.png", destination)
print(f"Rendered {count} frames at {args.fps} fps; movie {output.stat().st_size:,} bytes. Temporary frames removed.")
