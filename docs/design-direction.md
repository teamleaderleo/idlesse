# Idlesse visual direction

Idlesse should feel like a quiet place for artwork, with a small amount of personality.
The curled sleeping cat marks the app; the artwork supplies most of the color.
Controls retain macOS appearance, accessibility, keyboard behavior and accent color.

The Library is now artwork-first at catalog scale. A native source-list sidebar holds
All Wallpapers, Favorites, Included, Imported, Library 2 Source catalogs and Collections. The main browser opens
in a native `NSCollectionView` gallery with restrained 16:9 artwork cards and titles
below the image. A Gallery/List segmented control preserves the compact list browser;
both modes share the same selected-item detail column, large 1024 × 576 composed still,
favorite control and Set Wallpaper/Edit/More actions. Selection follows a wallpaper ID
through filtering, sorting and mode switches.

Gallery cards are still images. They never host a live scene renderer or continuously
playing video. Artwork work follows the visible range with a small near-visible band
and is cancelled as cells move away. Library 2 explicit poster paths, sidecars and package `preview.jpg` files are used
first; ImageIO downsamples stills and `AVAssetImageGenerator` is capped at 384 × 216.
Packages without a preview sidecar may use one serial 384 × 216 composed still render
while they are near the viewport. The gallery keeps an exact 16 MiB decoded-pixel LRU
budget plus a 96-entry metadata/image cap. The selected-detail cache remains four
1024 × 576 posters, exactly 9 MiB of raw pixels. See `docs/library-gallery.md` for cancellation,
decoder and cloud-backed-file details.

The gallery selection ring uses the system accent color while the cards themselves stay
quiet. Return sets the selected wallpaper, arrows move selection, Space shows the already
prepared large still in a transient preview, and Command-F focuses Library search.
Removal language says “Library Reference” and confirms that source media stays in place.

Known restoration/codec suffixes are hidden in display names; catalog titles and files
are unchanged. Collection playback, schedules, import conversion, scene format and the
runtime animation/rendering model remain unchanged by the gallery work.

After Hours replaces its typography/geometric demo with an original generated
night-window illustration and twelve restrained window motes. The illustration is
1672 × 941; it is not native 4K. The packaged JPEG is about 436 KiB. Motes can be
disabled through the scene's Window Motes control. Existing user copies are separate.

The cat mark was generated for this app. Assets/Idlesse.png is the source;
scripts/build-icon.sh creates the macOS ICNS representation, including small sizes.
The app and saver builds embed it; the menu bar uses a monochrome system cat symbol.

References informing the direction (not copied artwork):
- GNOME gallery guidance: https://developer.gnome.org/hig/patterns/containers/grid-views.html
- GNOME background guidance: https://developer.gnome.org/hig/reference/backgrounds.html
- Catppuccin's restrained desktop palette: https://github.com/catppuccin/catppuccin

The application menu includes the native About panel, Hide (⌘H), Hide Others
(⌥⌘H), and Show All commands. The About panel uses the packaged icon and version.

The final cat uses tapered closed eyes, whiskers and asymmetric tucked paws on
a muted plum tile. Assets/Idlesse.png has true alpha outside the rounded tile,
removing the pale border from the earlier Dock version. Installed build 17
embeds the replacement ICNS at standard macOS sizes.
