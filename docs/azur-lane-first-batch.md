# First Azur Lane wallpaper batch

2026-09-10. Finished locally, reviewed, and copied with SHA-256 verification to the existing Google Drive sync folder. Remote upload is not confirmed. Library import is pending because the Mac was locked; the running wallpaper was not changed.

## Outputs

13 HEVC videos, all 3840×2160 at 60 fps, with posters and source receipts:

- Perseus — Spring’s Lackadaisical Leisure
- Plymouth — An Angelic Physical
- Jean Bart — Private Après Midi; First Snow Upon the Cutlass’s Edge; Springlight Étoiles
- Richelieu — Fleuron of the Waves; Evergreen Prophecy
- Clemenceau — Splendid Breeze
- Vanguard — base; Half-Hearted Masquerade
- Tiger — base; Maiden of the Stars
- Max Immelmann — base

Two stills: Jean Bart — Uninhibited Bloodstone, composed over its background at 4K; Chen Hai — Cerulean Ripples, preserved at source resolution. These were not misclassified as Live2D.

The sexualized I-14 and Black★Rock Shooter requests were excluded because of their underage/childlike depiction. No derivatives were made or archived for them.

Local outputs: `~/Pictures/Wallpapers/Azur Lane/{Animated,Static}`. Drive uses `Idlesse/{Originals,Restored,Previews,Catalogs}/Azur Lane`. The archive receipt covers 45 files / 715,531,862 bytes. No playback assets were evicted.

Kazusa regular and Kazusa (Band) were also completed through the existing Blue Archive restoration pipeline: two 4K60 clips, fully decoded and visually sampled, archived separately under Blue Archive. Library import is likewise pending. Other story-only Kazusa variants did not have matching lobby bundles in this catalog.

## Validation and limits

All 6,989 Azur video frames passed full VideoToolbox decode and frame-count checks. Serial export plus validation took 357.75 seconds in this run, about 19.5 output frames per wall-clock second; videos total 444.4 MB. This excludes download/setup/preview/archive time and is not a general performance guarantee. Playback cadence is 60 fps.

First/middle/last contact strips were inspected for all 13 clips. Seam mean absolute RGB differences at 512×288 range from 0.37 to 1.11 on a 0–255 scale. This is diagnostic, not a proof of perfect temporal continuity; boundary velocities and in-game parity have not been exhaustively compared. The three base illustrations retain their full rigging on a plain backdrop.

Live2D advances physics in fixed 1/60-second steps after three idle cycles of warmup. Spine uses authored normal loops; base Vanguard retains both layers. The exports omit interaction gestures, voices, and unsupported Unity-specific effects/particles. Original textures rendered at 4K do **not** mean native 4K source detail, and these Azur files were not AI-upscaled.

## Reproducible workflow

See [scripts/azur-lane](../scripts/azur-lane/README.md). The reviewed plan, camera recipes, Live2D/Spine adapters, source preparation, previews and resumable export runner are tracked. Game assets and Cubism Core are not committed. Preparation was tested against the selected 13 models; export resume verified all 13 output hashes without rendering again. Python syntax and path-containment tests passed.

Sources are complete game models mirrored by [Nagami](https://azurlane.nagami.moe/live2d-viewer), not publisher-distributed wallpapers. Captured data revisions: Live2D 1788878728; Spine 1788951076. Original manifests, textures, motions and receipts are retained with the archive.

Publisher notices corroborate the requested [February outfits](https://azurlane.yo-star.com/news/2026/02/25/maintenance-notice-2-26-12-a-m-utc-7/) and [September dynamic additions](https://azurlane.yo-star.com/news/2026/09/07/maintenance-notice-9-8-12-a-m-utc-7/). The latter also lists two possible future adult-character additions: Illustrious — Wandering Glow of Midnight and Lion — Alleyway Temptress. They have not been downloaded.

## Import completion

The Mac UI helper was restarted on September 10. All 13 animations, two stills, and both Kazusa versions were imported through the native Library; the catalog reached 105 entries. Subsequent Himari/Kasumi corrections brought it to 107. Kayoko New Year remained active.
