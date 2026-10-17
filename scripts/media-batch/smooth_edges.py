"""Smooth stair-stepped silhouettes in restored lobby textures.

The art draws a 1px dark outline right at many alpha silhouettes, so upscaling
the alpha with Lanczos keeps every source pixel's step. Running the alpha through
the upscaler ("the mask", in assets-ai-masks) smooths those steps, but it also
reshapes things: it widens gaps meant to taper, hardens lace and changes soft
smoke. So the mask is only trusted where it stays close to the Lanczos alpha
locally (a step, not a reshape), and not at all in dense or soft transparency.

Colour is never touched. Result: assets-ai-smooth/<asset>, rendered in place of
assets-ai-batch/<asset>.
"""
import shutil, sys
from pathlib import Path
from PIL import Image, ImageChops, ImageFilter

MASKS, SMOOTH = 'assets-ai-masks', 'assets-ai-smooth'
VERSION = 'smooth-edges 1: mask where local diff 12-40 over r3; kept where soft alpha covers 24-43% of r12'
# The mask replaces the Lanczos alpha where their local difference is at most
# DIFF_LOW, fading out by DIFF_HIGH (0-255 after a BoxBlur of DIFF_RADIUS).
DIFF_LOW, DIFF_HIGH, DIFF_RADIUS = 12, 40, 3
# Partially transparent pixels covering more than this share of a neighbourhood
# mean lace, hair wisps or smoke rather than one outlined edge: keep those as painted.
SOFT_LOW, SOFT_HIGH, SOFT_RADIUS = 60, 110, 12


def ramp(image, low, high):
    """255 at or below `low`, 0 at or above `high`, linear between."""
    return image.point(lambda v: 255 if v <= low else 0 if v >= high else round(255 * (high - v) / (high - low)))


def blend(alpha, mask):
    """Alpha for one texture page: the mask where it only smooths, the Lanczos alpha elsewhere."""
    near = ramp(ImageChops.difference(alpha, mask).filter(ImageFilter.BoxBlur(DIFF_RADIUS)), DIFF_LOW, DIFF_HIGH)
    soft = alpha.point(lambda v: 255 if 8 < v < 247 else 0).filter(ImageFilter.BoxBlur(SOFT_RADIUS))
    weight = ImageChops.multiply(near, ramp(soft, SOFT_LOW, SOFT_HIGH))
    return Image.composite(mask, alpha, weight)


def has_masks(workspace, asset):
    restored, masks = workspace / 'assets-ai-batch' / asset, workspace / MASKS / asset
    return restored.is_dir() and all((masks / png.name).exists() for png in restored.glob('*.png'))


def build(workspace, asset):
    """Write assets-ai-smooth/<asset> from the restored textures and their masks; returns its folder."""
    restored, masks, dest = workspace / 'assets-ai-batch' / asset, workspace / MASKS / asset, workspace / SMOOTH / asset
    stamp = dest / '.smooth'
    sources = sorted(p for p in restored.iterdir() if p.is_file())
    if stamp.exists() and stamp.read_text() == VERSION and all(
            (dest / p.name).exists() and (dest / p.name).stat().st_mtime >= p.stat().st_mtime for p in sources):
        return dest
    staging = dest.with_name(dest.name + '.partial')
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    for path in sources:
        if path.suffix != '.png':
            shutil.copy2(path, staging / path.name)
            continue
        image = Image.open(path).convert('RGBA')
        mask = Image.open(masks / path.name).convert('L')
        if mask.size != image.size:
            raise RuntimeError(f'{asset}/{path.name}: mask is {mask.size}, texture is {image.size}')
        image.putalpha(blend(image.getchannel('A'), mask))
        image.save(staging / path.name, format='PNG', compress_level=3)
    (staging / '.smooth').write_text(VERSION)
    shutil.rmtree(dest, ignore_errors=True)
    staging.rename(dest)
    return dest


if __name__ == '__main__':
    root = Path(sys.argv[1])
    for name in sys.argv[2:]:
        print(build(root, name), flush=True)
