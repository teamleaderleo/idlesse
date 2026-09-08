# Wallpaper compression experiment — 2026-09-08

Same 3840×2160 dimensions and 60 fps; HEVC VideoToolbox, 12 Mbps target,
hvc1 MP4, fast-start, audio omitted, container metadata stripped. Originals retained.

| Source | Original bytes | HEVC bytes | Reduction | Full-video SSIM |
|---|---:|---:|---:|---:|
| Mika animated illustration | 130265545 | 20378520 | 84.4% | 0.985476 |
| Shiroko Terror | 120247167 | 12309008 | 89.8% | 0.991084 |

Both passed the production WallpaperController smoke suite, including looping,
pause, sleep/session overlap and stop. Mika at four seconds was compared visually
side by side at reduced display size; no obvious difference at that size. This is
lossy compression, not proof of indistinguishability at native size. SSIM is a
pixel similarity metric, not a perceptual guarantee. No RAM or energy savings
were measured. Encoding dimensions do not establish native source detail.

Mika source: https://wallpaperwaifu.com/anime/misono-mika-smiling-blue-archive-live-wallpaper-1890/
This is an animated illustration, not the requested in-game Memorial Lobby.
Shiroko source: https://moewalls.com/anime/shiroko-terror-blue-archive-live-wallpaper/

Local derivatives live under ~/Pictures/Wallpapers/Blue Archive/Optimized.
Media is not committed to this repository.

Reproduction (provide separate input and output paths):

```sh
ffmpeg -i INPUT.mp4 -map 0:v:0 -c:v hevc_videotoolbox -b:v 12000k \
  -tag:v hvc1 -an -map_metadata -1 -movflags +faststart OUTPUT.mp4
ffmpeg -i OUTPUT.mp4 -i INPUT.mp4 -lavfi ssim -an -f null -
```

Cloud archive: Vivian Trust and Dress Hina originals uploaded and remote sizes
verified through Drive metadata. The connector rejected the 130 MB Mika original
before upload because of its 100 MiB transfer limit. No local originals deleted;
iCloud unchanged. Cloud-only originals plus bounded local playback derivatives
remain the intended arrangement; automatic archival and eviction are not implemented.
