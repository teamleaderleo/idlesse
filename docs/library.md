# Idlesse Library

Open Library from the preview window or Wallpaper menu (Command-L).

- Six bundled scenes: Undertow, Fireflies, Ripple, Audio Aurora, Aurora, Breathing Aurora.
- Search by name; filter built-in/imported/favorites; sort by name or recently opened.
- Select a scene for a still poster. Double-click or Use on Desktop applies it.
- Open in Studio edits imported packages. Built-ins always become untitled drafts.
- Make a Copy in Studio starts a draft without overwriting its source.
- Remove from Library removes the reference and favorite/recent metadata, never the media.

Imported files stay in their existing folder, including cloud-backed folders. The
index keeps security-scoped bookmarks under Application Support/Idlesse/Library,
with up to 128 imports and a 1 MiB index limit. A corrupt index is preserved and
reported, not overwritten. A moved/unavailable file can be re-added through the picker.

Posters are generated only for the selected scene. Procedural/image compositions
are rendered at scene time 2 seconds with pointer/audio grants off, then their GPU
resources are released. Video scenes show a thumbnail of their first video node;
Studio supplies the complete moving composition. This is a still-preview library,
not a grid of continuously playing wallpapers.

The memory cache holds at most eight 512-square posters (about 8 MiB pixel data).
There is no disk thumbnail cache or original-media duplication. Renderer working
memory uses the existing scene budgets during generation. Refresh Preview updates
a poster after external edits. Closing the Library cancels its request and clears
the image cache.

Still missing: user collections, scheduled scene rotation, drag-and-drop import,
automatic preview invalidation, and full video-composition posters. Imported
cloud-backed media may need to download when explicitly selected for preview.

Validation includes index round trips/removal preservation, generated Metal posters,
favorite filtering, empty searches, and built-in routing to a Studio draft. The
offscreen UI capture exercises layout but cannot fully reproduce macOS glass-control
appearance; live UI validation remains separate from those tests.
