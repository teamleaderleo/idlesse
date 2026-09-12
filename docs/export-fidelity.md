# Export fidelity

New media-batch exports prefer 10-bit HEVC Main10 at the existing 40 Mbit/s target. Existing completed catalog files stay byte-for-byte where they are: the resumable batch runner continues to reuse hash-verified checkpoints, and this change does not trigger catalog re-export or re-mirroring.

This work improves encoded-asset fidelity and verifies playback compatibility. The current Metal scene path requests 8-bit BGRA video frames and renders to an 8-bit SDR target, so compositor precision beyond 8 bits remains separate follow-up work.

## Policy

`IDLESSE_EXPORT_BIT_DEPTH=10` is the default for new exports. Set `IDLESSE_EXPORT_BIT_DEPTH=8` for an explicit compatibility export on a machine or downstream target that requires HEVC Main. Both frame-encoder modes use lossless PNG input; the override changes the final HEVC profile/pixel format only.

The default WebCodecs/Mediabunny route requests `hvc1.2.4.L153.B0`, the 4K60 HEVC Main10 profile/level used by the 40 Mbit/s batch. It asks `VideoEncoder.isConfigSupported()` before rendering. `encode.py` then probes the returned MP4 and accepts the result only when FFprobe reports both `Main 10` and a 10-bit pixel format. A rejected or mis-signalled WebCodecs encode exits non-zero, so the batch runner's existing one-shot recovery path selects the frame/FFmpeg encoder.

The frame encoder uses `hevc_videotoolbox`, `hvc1` and the same 40 Mbit/s target. Main10 selects `yuv420p10le` plus `-profile:v main10`; the compatibility path selects `yuv420p`. WebKit feeds lossless PNG frames into FFmpeg for both paths. The previous JPEG-99 intermediate reduced the deterministic 85-level gradient source to 82 levels before video encoding and introduced 0.315 mean absolute RGB error, so frame transport now stays lossless regardless of final codec bit depth.

If Main10 is unavailable in both encoders, the batch fails explicitly. Operators can rerun with `IDLESSE_EXPORT_BIT_DEPTH=8` after choosing compatibility over gradient precision.

## Repeatable precision check

`gradient_precision.py` generates a deterministic warm gradient, encodes it at 40 Mbit/s through HEVC Main and Main10, decodes each result through 16-bit RGB, and counts distinct green levels down four fixed columns. Decoding to 16-bit RGB is deliberate: converting Main10 directly to `rgb24` quantizes before measurement and hides part of the retained precision.

On the Linux/libx265 development check used while implementing #49:

| path | mean distinct G levels | gap from 85 | encode time | file size |
| --- | ---: | ---: | ---: | ---: |
| HEVC Main / 8-bit | 70 | 15 | 0.866 s | 14,136 B |
| HEVC Main10 / 10-bit | 83 | 2 | 1.281 s | 13,425 B |

For this one-second static probe, Main10 took 1.48× the software encode time and produced a 0.95× file. The file-size sample is intentionally tiny; production decisions should use the same scene, duration and 40 Mbit/s target on the export Mac. The precision result is the gate: Main10 must remain within a single-digit level gap.

Run the production encoder probe on macOS with:

```sh
python3 scripts/media-batch/gradient_precision.py \
  --encoder hevc_videotoolbox \
  --output-json build/main10-gradient.json
```

The script exits non-zero if the 8-bit signal no longer reproduces measurable loss, Main10 exceeds the single-digit gap budget, or the 10-bit output is mis-signalled.

## Batch QA

`verify.py` keeps the existing seam diagnostics and edge-bar gate. Add `--require-main10` when reviewing new Main10 work:

```sh
.venv/bin/python scripts/media-batch/verify.py \
  --root build/ba-export-study \
  --require-main10
```

For a real gradient-heavy scene, provide a lossless frame plus the exact crop/columns used for the comparison. A plan is JSON keyed by the batch item ID:

```json
{
  "items": {
    "scene-id": {
      "reference": "references/scene-id-lossless.png",
      "time": 0,
      "crop": [1200, 180, 1100, 700],
      "columns": [100, 350, 700, 1000],
      "channel": "g",
      "maxLevelGap": 9
    }
  }
}
```

Then run:

```sh
.venv/bin/python scripts/media-batch/verify.py \
  --root build/ba-export-study \
  --require-main10 \
  --gradient-plan build/gradient-plan.json
```

The report records codec profile, pixel format, source/encoded level counts and the gap in `visual-qa.json`. A configured gap above the recipe budget fails verification.

## Playback compatibility and compositor boundary

`Tests/Fixtures/tiny-main10.mp4.b64` stores a six-frame HEVC Main10 fixture; the smoke script decodes it into its temporary directory. `test-wallpaper.sh` sends it through the normal wallpaper player, Library smoke path and offline Metal scene export. That verifies native `AVPlayerLayer` compatibility, Library video poster/import handling, and successful decode/render through the `MetalSceneRenderer` path.

The Metal renderer currently asks AVFoundation for `kCVPixelFormatType_32BGRA` frames and uses an 8-bit SDR render target. The Main10 fixture therefore proves compatibility through custom composition, while the export gradient probe is the evidence that the stored asset retains the extra source precision. Preserving more than 8 bits through custom Metal composition requires its own pixel-buffer, conversion, render-target and color-management contract.

No committed game media is required for these checks.
