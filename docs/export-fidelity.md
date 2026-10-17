# Export fidelity

New media-batch encodes default to HEVC Main10 at the existing 40 Mbit/s target. Set `IDLESSE_EXPORT_BIT_DEPTH=8` to request an explicit HEVC Main compatibility encode through the WebCodecs or frame-encoder routes. The dedicated `--encoder x265` path remains the lossless-frame Main10 software route it already was.

This policy preserves encoded-asset precision. The current custom Metal video compositor still requests 8-bit BGRA frames and renders through an 8-bit SDR target, so compositor precision beyond 8 bits remains a separate renderer/color-management contract.

## Encoder contract

The default WebCodecs/Mediabunny route preflights `hvc1.2.4.L153.B0` through `canEncodeVideo` when 10-bit output is requested and passes that fully qualified codec string to `CanvasSource`. `encode.py` FFprobes the completed MP4 before publishing it and accepts Main10 only when FFprobe reports both the `Main 10` profile and a 10-bit pixel format. The 8-bit compatibility route similarly rejects a Main10/10-bit result.

If WebCodecs cannot satisfy the requested route, the existing one-shot fallback uses the frame encoder. Frame transport is lossless PNG for both bit depths; the final encoder remains VideoToolbox at 40 Mbit/s, with `yuv420p10le` + `main10` for the default route and `yuv420p` for the compatibility route. The frame encoder also FFprobes its result before returning.

The separate x265 path continues to send raw RGBA frames from WebGL directly into FFmpeg and encode `yuv420p10le` Main10. It avoids the PNG/base64 overhead of the frame fallback while retaining the same stored-precision goal.

The existing color-normalization pass uses stream copy plus HEVC metadata rewriting; it does not re-encode the video payload. Current camera recipes, framing/bleed, calibration, import behavior, range/matrix decisions and `write_colr` behavior remain unchanged.

## Repeatable precision check

`scripts/media-batch/gradient_precision.py` generates a deterministic warm gradient, encodes it at 40 Mbit/s through HEVC Main and Main10, decodes each result through 16-bit RGB, and counts distinct green levels down four fixed columns. The Main10 result must stay within a single-digit level gap from the source, while the 8-bit path must reproduce measurable quantization loss.

Run the native encoder probe on macOS with:

```sh
python3 scripts/media-batch/gradient_precision.py \
  --encoder hevc_videotoolbox \
  --output-json build/main10-gradient.json
```

## Native compatibility and broad smoke

`Tests/Fixtures/tiny-main10.mp4.b64` stores a tiny HEVC Main10 fixture. `test-media-compat.sh` reconstructs it in disposable state, requires a Main10/10-bit FFprobe result, then exercises video candidate preparation, Library video handling and offline Metal-backed scene export. It also runs the native VideoToolbox gradient probe.

This deterministic media gate runs separately from the canonical wallpaper smoke. Real-display qualification can still be run when needed, while host timing cannot hide a deterministic codec, Library or renderer regression.

The canonical `--smoke-wallpaper` remains the broad post-media runtime gate.
