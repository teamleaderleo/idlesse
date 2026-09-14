#!/usr/bin/env python3
"""Shared bit-depth policy and stream verification for media-batch encoders."""
import json
import os
import subprocess


def requested_bit_depth(env=None):
    env = os.environ if env is None else env
    raw = env.get('IDLESSE_EXPORT_BIT_DEPTH', '10')
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise ValueError('IDLESSE_EXPORT_BIT_DEPTH must be 8 or 10')
    if value not in (8, 10):
        raise ValueError('IDLESSE_EXPORT_BIT_DEPTH must be 8 or 10')
    return value


def is_ten_bit_pixel_format(pixel_format):
    value = (pixel_format or '').lower()
    return '10' in value or value.startswith('p010')


def stream_matches_bit_depth(stream, bit_depth):
    if stream.get('codec_name') != 'hevc':
        return False
    ten_bit = is_ten_bit_pixel_format(stream.get('pix_fmt'))
    if bit_depth == 10:
        return stream.get('profile') == 'Main 10' and ten_bit
    if bit_depth == 8:
        return stream.get('profile') != 'Main 10' and not ten_bit
    return False


def ffprobe_stream(path, ffprobe='ffprobe'):
    data = subprocess.check_output([
        ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=codec_name,profile,pix_fmt', '-of', 'json', str(path)
    ])
    streams = json.loads(data).get('streams', [])
    if len(streams) != 1:
        raise RuntimeError(f'Expected one video stream in {path}; found {len(streams)}')
    return streams[0]


def require_stream_bit_depth(path, bit_depth, ffprobe='ffprobe'):
    stream = ffprobe_stream(path, ffprobe=ffprobe)
    if not stream_matches_bit_depth(stream, bit_depth):
        raise RuntimeError(
            f'Expected HEVC {bit_depth}-bit output; got profile={stream.get("profile")} '
            f'pix_fmt={stream.get("pix_fmt")} codec={stream.get("codec_name")}')
    return stream
