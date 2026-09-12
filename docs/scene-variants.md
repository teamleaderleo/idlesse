# Scene variants

Revision 21 packages can declare the `variants` feature and store named scene variants in `scene.json`.

A persisted variant contains a stable UUID, a user-visible name, and a sparse `values` dictionary keyed by existing scene-control IDs. Values use the control's scalar value only: numbers, booleans, colors, choices, and strings. Variants do not introduce new control kinds or target arbitrary node/style/motion properties in v1.

`Default` is synthetic. It is the canonical authored scene and is never stored as a variant record. A named variant inherits every control value it does not override, so later edits to Default flow through automatically.

Runtime composition uses one canonical order:

1. canonical authored scene (Default)
2. selected persisted variant delta
3. temporary runtime-control edits

Switching variants starts again from the canonical authored scene, applies the selected sparse delta, then reapplies the current temporary layer as appropriate for the caller. `SceneDescriptor.applyingVariant(id:)` implements the persisted layer and returns diagnostics alongside the effective descriptor.

Scene evolution is tolerant at application time. An override whose control disappeared, changed type, moved outside its numeric range, or lost a choice is skipped while compatible overrides continue to apply. The stale entry remains persisted so a later compatible scene revision can use it again. A missing variant UUID falls back to synthetic Default with a diagnostic.

Hard bounds keep package decoding and editor operations predictable:

- 16 named variants per scene
- 16 overrides per variant
- 16 KiB maximum encoded variant payload
- unique UUIDs and case-insensitive names
- names limited to 80 characters
- control IDs limited to 64 UTF-8 bytes
- scalar string values limited to 4096 UTF-8 bytes

Packages with variants must declare `variants` in the revision-21 manifest feature list. Packages and recovery records that predate the field decode with an empty variant list. Writers omit both the scene block and feature declaration when no named variants exist.

Library grid thumbnails continue to represent canonical Default. Variant-specific selected-detail posters and wallpaper resume state layer on this model in the user-facing #32 slices.


## Product integration

Library selected-detail previews may choose an authored variant, while ordinary grid/list thumbnails stay on Default. Collections persist `SceneSelection(sceneID, variantID)`; legacy `sceneIDs` decode as Default.

Wallpaper playback keeps three layers separate: the resolved package scene, the selected authored variant, and session-only control changes. Switching a variant clears the temporary control layer and updates live surfaces in place, preserving scene time and media phase. The selected variant UUID is saved beside the wallpaper bookmark, while ad-hoc control edits remain session-only. The menu/status title appends the variant name and `Modified` when temporary controls differ from that variant. System backdrop stills are regenerated from the same effective scene.


## Studio authoring

Scene Controls contains a synthetic **Default** entry plus authored named variants. Creating, renaming, duplicating and deleting variants is staged inside the sheet; Apply records one document Undo step and Cancel restores the original in-place preview. Each control shows Default, Inherited or Override, and overridden controls expose **Use Default**. Named variants persist only values that differ from Default.

Studio keeps the selected variant as editor session state. Switching variants updates the current renderer in place, so scene time and playing media keep their phase. Library Edit carries the selected variant into Studio, and **Use on Desktop** carries it back to wallpaper selection.
