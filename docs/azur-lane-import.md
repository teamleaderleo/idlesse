# Azur Lane animated skins: ingestion study

Checked 2026-09-10. Three game bundles were retrieved for inspection; no Azur Lane wallpaper has been imported yet.

## Recommended first route

Use original game assets from a user's installation, select one idle motion, inspect it against the game, and render a full loop to 3840×2160 HEVC. The resulting video fits Idlesse's existing Library, scheduling, and hardware playback. Keep original assets on Drive, with a small poster and provenance receipt alongside the playback derivative. A 4K render is not a claim of native 4K texture detail.

Live2D and Spine require different renderers. Blue Archive's Spine pipeline cannot directly read Live2D `.moc3` files. Preserve model JSON, textures, motions, expressions and physics together; an isolated texture PNG is insufficient.

## Candidates

[AzurLaneRenderer / AzurLaneSkinRenderer](https://github.com/EnderAvaritia/AzurLaneRenderer) is an Android application. Its README documents Live2D, Spine and static painting extraction/rendering, individual motion controls, looping, and a v0.11.0 changelog dated August 4, 2026. It uses GLES and Android file-access mechanisms; this is not a ready-made macOS plugin. The source is useful for discovering bundle layouts and checking motion selection. Its broad compatibility claims remain upstream claims until we test our chosen assets.

[Azure Gravure](https://github.com/bungaku-moe/Azure-Gravure) is a Unity project rather than a packaged Mac integration. [ProjectVersion.txt](https://github.com/bungaku-moe/Azure-Gravure/blob/dev/ProjectSettings/ProjectVersion.txt) requests Unity 6000.0.48f1. [CharacterViewer.cs](https://github.com/bungaku-moe/Azure-Gravure/blob/dev/Assets/Scripts/Components/CharacterViewer.cs) loads model3 JSON and Cubism components, but explicitly leaves the physics controller disabled because the physics rig becomes null. This makes it an exploratory reference, not a fidelity baseline.

## Small implementation milestone

1. Acquire one chosen skin's complete files from an installation; retain region/client version and hashes.
2. Verify texture sizes, motion durations, blend/mask behavior and physics against the game.
3. Render at fixed 1/60-second steps after a physics warmup. Unlike the current analytical Spine export, stateful Live2D physics must advance continuously.
4. Compare start/end frames and motion velocity. A loop toggle alone does not prove a seamless boundary; avoid arbitrary crossfades until the authored idle is understood.
5. Export HEVC, decode/count all frames, inspect first/middle/end and the boundary, generate a 1024-wide poster, then import.

Later, a dedicated Live2D renderer could retain touch/motion selection without a pre-rendered clip. That requires a Cubism runtime/licensing review and resource/lifecycle integration; it should not embed a whole Unity player per wallpaper. Do not bundle game assets or assume the viewer's license covers the game art or its SDK dependencies.

## Connected-device findings

USB ADB was already authorized. Azur Lane EN (`com.YoStarEN.AzurLane`) is installed, app version 9.3.7, Live2D asset version 0.0.959. The readable Live2D folder contains 259 files (not necessarily 259 distinct skins; alternate variants occur).

Retrieved approximately 20.7 MB total, with SHA-256 receipts in the local study workspace:

- Belfast — Iridescent Rosa (`beierfasite_2`): one 2048×2048 texture, 15 Unity animation clips, physics JSON.
- Atago — Summer March (`aidang_2`): one 2048×2048 texture, 14 clips, physics JSON.
- Ägir — Iron Blood's Dragon Maid (`aijier_2`): one 4096×4096 texture, 15 clips, physics JSON.

Names were matched against [AzurLaneTools' extracted EN skin table](https://github.com/AzurLaneTools/AzurLaneData/blob/main/EN/ShareCfg/ship_skin_template.json). UnityPy read the bundles successfully. Model data is stored in Unity components, not an already-exported standalone model3 directory, so the next concrete step is Cubism model/motion reconstruction. None of these atlas dimensions prove a native 4K full-screen image. No APK, emulator or Unity editor was installed and nothing on the phone was changed.
