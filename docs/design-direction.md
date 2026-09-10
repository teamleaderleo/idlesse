# Idlesse visual direction

Idlesse should feel like a quiet place for artwork, with a small amount of personality.
The curled sleeping cat marks the app; the artwork supplies most of the color.
Controls retain macOS appearance, accessibility, keyboard behavior and accent color.

The Library uses a large 16:9 artwork preview, a compact title/favorite row and one
primary Set Wallpaper action. Edit stays visible; copy, refresh and removal live
under More. Collections sit next to filtering. Sidebar destinations use symbols and
subtle selection backgrounds instead of a stack of gray push buttons. No new live
thumbnail grid or extra video decoders were introduced. Selected posters now render
at 1024 × 576, with four cached images (9 MiB of raw pixels) instead of eight
512 × 288 images (4.5 MiB). This is a bounded quality tradeoff for the larger preview.
Known restoration/codec suffixes are hidden in display names; catalog titles and
files are unchanged.

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

This pass is an artwork-first detail browser, not a completed multi-thumbnail gallery.
A future grid needs visible-item loading, cancellation and an explicit memory budget.

The application menu includes the native About panel, Hide (⌘H), Hide Others
(⌥⌘H), and Show All commands. The About panel uses the packaged icon and version.

Validated in installed build 14: native About icon/version, Library layout and clean
display names, More actions and disabled removal for included scenes. Wallpaper,
Library, export and resume smoke suites passed. The active wallpaper was preserved.

The final cat uses tapered closed eyes, whiskers and asymmetric tucked paws on
a muted plum tile. Assets/Idlesse.png has true alpha outside the rounded tile,
removing the pale border from the earlier Dock version. Installed build 17
embeds the replacement ICNS at standard macOS sizes.
