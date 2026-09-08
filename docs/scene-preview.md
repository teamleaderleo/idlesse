# Scene Preview

Open **Scene Preview…** from the preview controls or Wallpaper menu (⌘O).
The separate workbench opens an image, video, or `.idlesse` package without changing
the desktop. A built-in Aurora scene makes it usable with no downloads.

- Pause/resume and compare Standard with Metal · Experimental.
- Opened packages hot-reload through SceneWatcher. Invalid metadata or an unplayable
  video keeps the previous preview; asynchronous renderer errors appear in the subtitle.
- Use on Desktop closes the preview and hands the source to the wallpaper host.
  The comparison control affects only the preview; the desktop retains its own renderer selection.
- Closing releases the renderer. Hidden/minimized previews, system sleep, and Low
  Power Mode pause playback. Opening Scene Preview stops the saver preview behind it.
- Resize completion rebuilds at the new image decode budget. Video playback restarts
  on resize or renderer switching; this is not a synchronized frame comparison.

Verified with native UI: open/close/reopen, standard and Metal Aurora rendering,
Jane Trust video, Evelyn Illustration 4K video in Metal, and the pause control.
Build, decoder/scene tests and wallpaper/GPU smoke tests pass. Energy and native-size
color parity remain separate compositor promotion gates. This is a preview workbench,
not yet a layer editor.
