# Desktop attention signal

Scenes may opt into one privacy-preserving host input by declaring the
`desktop-attention` capability in a revision-21 package. A binding using
`desktop.attention` receives `1` when the wallpaper is exposed and `0` when
other opaque windows cover the display, with intermediate values following the
visible fraction.

The signal exposes no window names, processes, titles, or geometry. It reuses
the wallpaper coverage sample and remains available when coverage-rest is
disabled; the rest policy still decides independently whether a renderer may
pause.
