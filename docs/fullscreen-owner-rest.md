# Fullscreen-owner rest

When coverage rest is enabled, the existing single window-list sample also
checks for one opaque window that covers the complete display. Elevated-layer
borderless windows qualify directly; layer-0 windows qualify only when the
window has no title, which keeps ordinary titled maximized windows on the
hysteretic coverage path.

Fullscreen rest is tracked separately from ordinary coverage rest. It resumes
on the next sample when the owner disappears, while shared video playback
still stays alive for any display that remains visible.

Desktop qualification reports also record measured loop-boundary intervals per
display. The first loop establishes a baseline; later samples report elapsed
seconds per loop without changing the playback path.
