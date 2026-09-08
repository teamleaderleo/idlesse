# Wallpaper mode

Idlesse.app now has a wallpaper host alongside its existing screensaver preview.
The .saver's behavior and macOS's saved desktop wallpaper are unchanged.

## Use it

Open `build/Idlesse.app`, click **Wallpaper…**, and choose a local JPG/JPEG,
PNG, HEIC, MP4 or MOV. The file picker is attached to the preview. One borderless,
non-focusable, click-through window covers each display, below desktop icons.
Images use display-sized decoding; videos loop silently and fill the display.

An Idlesse picture icon in the menu bar provides Choose, Pause/Resume Video,
Stop Wallpaper, Show Preview and Quit. The app's Wallpaper menu has the same core
controls. Stop removes the desktop windows and returns to the preview. Quit
releases players and windows. The host does not register a login item, change
macOS wallpaper settings, copy media, download files or start automatically.

Video selection validates playability, duration and video tracks before replacing
the existing wallpaper. A failed image selection preserves the previous wallpaper.
Stop also cancels a pending selection.

## Resource behavior

- Static images have no wallpaper redraw or polling timer.
- A separate AVQueuePlayer/AVPlayerLooper serves each display. Video decoding is
  handled by AVFoundation; source resolution/frame rate are not transcoded or
  capped, and hardware decoding depends on the codec/device.
- Players are muted and do not prevent display sleep.
- Display sleep, system sleep and session deactivation release the windows and
  players. Overlapping sleep causes are tracked independently.
- Wake/session activation reconstructs only when all suspension causes clear.
- Low Power Mode pauses video. This is not an “on battery” setting.
- Display-change notifications rebuild the windows after a 300 ms debounce.
- Manual video pause holds its current frame and retains player resources.
- The preview stops and releases its slideshow images when wallpaper starts.

There is no automatic full-screen-app or window-occlusion pause yet. All-Spaces
and desktop layering are configured, but need broader testing across Spaces,
Mission Control, Stage Manager, full-screen apps and macOS releases.
Physical sleep/wake and monitor hot-plugging were not performed in this session.
The wallpaper host is intentionally separate from ScreenSaverView.

## Verification — 8 September 2026

Release build, strict signature verification, existing decoder/canvas/settings
checks, and `bash test-wallpaper.sh` pass. The wallpaper test uses a tiny generated
video, does not order test windows onscreen, and removes its fixtures. It verifies:

- Real AVPlayerLooper playback across a loop boundary.
- Image loading and failed replacement preserving the old wallpaper.
- Non-key/non-main windows that ignore mouse events and sit below icon level.
- Display/system sleep overlap, session deactivation and restoration.
- Pause, complete player release on Stop, and cancellation before load completes.

A separate 1280×720, 30 fps, two-second H.264 test video was selected through the
real file picker and visually inspected in the desktop window. Pause and Stop
were operated from the app menu. The final build was checked again: selecting
the movie opened Idlesse Wallpaper; Stop removed it and returned to Idlesse
Preview. The test app was then quit and the temporary video deleted.

The live Idlesse process held approximately 89–90 MiB physical footprint during
a 30-second video run. A CPU snapshot showed 6.1% of one core while playing and
0.0% after pausing. Paused footprint was about 87 MiB. These are short observations
of the whole app, after preview use, and **exclude decoder helpers and system GPU
costs**. They are not a power measurement or a product comparison.

To reproduce the automated checks, build first with
`CONFIG=release bash build.sh app`, then run `bash test-wallpaper.sh`.
The fixture generator uses an installed ffmpeg; playback uses macOS frameworks.
Tests require a logged-in macOS display session.

## Next steps

A standalone wallpaper control window, retained folder access and an opt-in
playlist; matching-resolution video derivatives; measured full-screen/occlusion
suspension; and Metal scenes with explicit frame-rate controls. Folder watching,
GIF/APNG animation, shaders and web wallpaper execution are not implemented.

## Platform references

- [AVPlayerLooper](https://developer.apple.com/documentation/avfoundation/avplayerlooper)
- [NSWindow canJoinAllSpaces](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces)

## Real-media follow-up

A fan-made [Astra Yao wallpaper from MotionBGS](https://motionbgs.com/astra-yao-zzz)
was downloaded for personal testing on 8 September. It is not official HoYoverse
content or bundled application media. The original single 20 MiB H.264 MP4 is
3840×2160, 30 fps, 11.23 seconds, with no audio. It is retained under
~/Pictures/Wallpapers/ZZZ/Animated alongside its source note; no derivative copies.

The real video passed the wallpaper smoke tests (including a loop boundary).
It was selected via the native picker, visually inspected in Idlesse Wallpaper,
and sampled for 30 seconds: 97–99 MiB process footprint. One CPU snapshot was
2.6% of one core. Decoder helpers and total GPU/system cost are excluded.
The process lifetime peak included preview use and was approximately 189 MiB;
this is not a wallpaper-only cold-start peak. The off-screen automated test had
a separate higher peak (~354 MiB), reinforcing that workload and metric matter.
Stop returned to Preview; the app was then quit and the original wallpaper restored.
See astra-wallpaper-evidence-2026-09-08.json for the measured samples.
