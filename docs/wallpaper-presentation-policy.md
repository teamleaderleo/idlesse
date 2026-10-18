# Wallpaper presentation policy

The global transport decision has one explicit precedence order:

1. session inactivity suspends the wallpaper;
2. display or system sleep suspends the wallpaper;
3. an explicit user pause pauses playback;
4. bedtime dimming pauses playback unless an Ambient mode owns the scene;
5. Low Power Mode pauses playback;
6. otherwise the wallpaper plays.

Per-display coverage rest remains separate because a shared video decoder must
stay alive while any connected display remains visible. Diagnostics report the
current global state and reason without changing those per-display rules.
