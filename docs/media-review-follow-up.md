# Media review follow-up — September 10, 2026

The 27 previously unprocessed Blue Archive wishlist scenes were individually re-reviewed from existing rendered source previews at full size. Karin (Bunny) used the earlier PC-source preview. These are scene-specific decisions, not a character blacklist, shipping application filter, or a restriction on nonsexual depictions of young characters.

## Decisions reversed

- **Hina:** clothed resting scene; being on a bed is not by itself sexual content.
- **Aris:** seated with knees drawn up beside gaming equipment; no sexual activity or intimate exposure.
- **Koharu (Swimsuit):** seated outdoor swimwear scene; swimwear and blushing alone are insufficient reasons to exclude it.
- **Fubuki (Swimsuit):** ordinary pool-float scene in a one-piece swimsuit.
- **Ui (Swimsuit):** seated poolside with a book and drink; no explicit or overtly sexual activity.

The restoration plan is `scripts/media-batch/plans/review-round-two.json`. Only authored `Idle_01` playback is included, with complete loop durations. Interaction/touch animations are not part of the exported wallpaper.

## Decisions retained for these particular scenes

Shigure (Hot Spring), Mimori (Swimsuit), Toki (Bunny), Hoshino (Swimsuit), Akane (Bunny), Ichika (Swimsuit), Karin (Bunny), Megu, Chinatsu (Hot Spring), Hanako, Hanako (Swimsuit), Satsuki, Eimi, Eimi (Swimsuit), Hiyori (Swimsuit), Hasumi (Track), Ayane (Swimsuit), Tsubaki, Asuna, Mashiro, Iori (Swimsuit), and Neru (Bunny).

The retained decisions concern sexualized framing, revealing poses, intimate exposure, or suggestive presentation of underage characters in these specific lobby compositions. They do not imply that every outfit, ordinary swimsuit scene, petite character, or animation from the game is sexualized. No existing user files were deleted or hidden as part of this review.

## Additional requested variants

Schale DB's current character metadata resolves Himari (Armed/Battle Suit) to **CH0332** and Hibiki (Cheer Squad) to **CH0181**. The matching Japan Windows 1.72.0 lobby assets were inspected directly. Both requested lobby compositions were excluded from restoration/import for sexualized presentation of underage characters. Regular Himari and regular Hibiki remain in the Library.

Sources: [Himari (Armed)](https://schaledb.com/student/himari_battle), [Schale DB character metadata](https://schaledb.com/data/en/students.json). Schale DB is a third-party game database. Game-source assets do not establish native 4K detail or exact parity with Unity playback.

The historical review files remain unchanged. This follow-up supersedes the five previous exclusions above.

## Completed batch

All five approved scenes were restored in one bounded L4 texture job, exported at 3840×2160/60 fps, fully decoded and sampled at first/middle/last frames, then imported through the native Library panel. The Library has 112 total entries; 90 of the original 112-item wishlist are now completed. Kayoko New Year remained the active wallpaper.

The five playback files total 385,649,383 bytes. Sixteen files totaling 637,536,866 bytes were copied into the existing Drive sync hierarchy with SHA-256 verification, including the source/restored archive and posters. Remote upload is unconfirmed; local playback files were retained. The batch plan is resumable and does not create a recurring GPU service.
