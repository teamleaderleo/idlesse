# ZZZ trust wallpaper samples

Downloaded unchanged community-hosted copies of in-game dynamic wallpapers on 2026-09-08: Vivian Banshee (9,842,294 bytes), Evelyn Chevalier (9,948,038 bytes), and Jane Doe (9,905,846 bytes).

All three are H.264, 960×540, 60 fps, 30 seconds, no audio. Total: 29,696,178 bytes (28.3 MiB). These are not publisher-provided desktop downloads or guarantees of original game resolution. Full-screen upscaling can look soft; no artificial upscaling or interpolation was applied.

Files and individual source notes live in `/Users/leoli/Pictures/Wallpapers/ZZZ/Animated/`, named `{Vivian,Evelyn,Jane}-Trust.mp4`.

Sources:
- https://zenless-zone-zero.fandom.com/wiki/File:Dynamic_Wallpaper_Vivian_Banshee.mp4
- https://zenless-zone-zero.fandom.com/wiki/File:Dynamic_Wallpaper_Evelyn_Chevalier.mp4
- https://zenless-zone-zero.fandom.com/wiki/File:Dynamic_Wallpaper_Jane_Doe.mp4

Frame inspection confirmed characters and lack of game interface overlays. Playback validation uses the actual WallpaperController and AVPlayerLooper with windows not ordered onscreen. See trust-wallpaper-tests-2026-09-08.json. This is not a fresh desktop/Spaces or resource benchmark.

The first Vivian run hit the test's 15-second loop deadline because the media lasts 30 seconds. Extended only the loop deadline to 60 seconds; state-transition deadlines remain 15 seconds.

## Blue Archive popularity

Game8 transcribes the Japanese fifth-anniversary broadcast's 2025 lobby-setting ranking. This measures usage, not an all-time aesthetic vote; character ownership affects it:

1. Hina (Dress)
2. Mika (Swimsuit)
3. Mika
4. Hina
5. Yuuka
6. Seia (Swimsuit)
7. Hoshino (Battle)
8. Mari (Idol)
9. Shiroko Terror
10. Hoshino (Swimsuit)

Source: https://game8.jp/blue-archive/661835

Linked broadcast: https://www.youtube.com/live/kgCwc2EHDgY?t=3488

The broadcast could not be fetched; ranking is attributed to Game8's transcription. Suggested initial shortlist: Hina (Dress), Mika, Hoshino (Battle), Shiroko Terror. No Blue Archive files downloaded in this pass.
