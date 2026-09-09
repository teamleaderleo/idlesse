# Reusable scene authoring — revision 21

New saves use manifest revision 21 and a sorted `features` array. The existing
V1–V20 decoders retain their version gates and normalize into SceneDescriptor.
Unknown features and missing declarations are rejected before rendering.
The supported vocabulary is owned by SceneFormat in Scene.swift; new capabilities
extend that vocabulary rather than advancing the whole container revision.

## Controls

Existing numeric controls retain their original JSON encoding and motion semantics.
Additional types are boolean, color, choice and string. Defaults use native JSON
values; colors use #RRGGBB or #RRGGBBAA in sRGB. Choices contain 1–32 unique options.
Text is bounded to 4,096 UTF-8 bytes. Numeric motion sources/modifiers explicitly
reject other types.

Controls can target a node UUID plus `visible`, `blend`, `text` or `fill`.
Targets are type checked; only one control owns each content property. Fill targets
text or shape layers; text targets text layers. Blend choices must be supported
blend names. These are discrete edits, not per-frame string/color animation.

Studio → + Create… → New Control… authors controls. Controls… exposes native
sliders, checkboxes, color wells, popups and text fields in Studio and on desktop.
Numeric controls connect using Bind…. Changing text/fill rebuilds the bounded
raster texture and may rebuild the renderer; motion transforms retain their
existing live-update behavior.

## Text and shapes

Text and shape layers require Metal. Text uses CoreText, with font name, size,
alignment, fill, line spacing and a 32–4096 pixel local canvas. Missing fonts use
the system font fallback; font files are not bundled, so typography can differ on
another Mac. Text is static content, not a live clock or lyric source.

Shapes support rectangle, ellipse, line and rounded rectangle. Text and shapes
rasterize once at preparation and participate in the shared 32-million-pixel image
allowance, with the existing per-input limit. They do not create animation timers.
Normal transforms, masks, blends, effects and scalar motion apply to both.

+ Create… adds Text/Shape and opens their content editor. Edit Text / Shape…
reopens it. Canvas handles retain placement, sizing and rotation.

## Package-local presets

+ Create… → Local Presets… captures the selected node/subtree together with its
internal bindings and controls. A preset may not reference a mask outside that
subtree. At most eight definitions are retained, inside scene.json; assets use the
normal contained, deduplicated package writer and security-scoped access.

Insert expands the preset to ordinary nodes and independent parameters. Node,
effect and parameter identities are fresh; binding and mask references are remapped.
The expanded result must pass the same 16-node, video, group, parameter, binding
and GPU memory budgets as manually authored content.

This first version is snapshot based. Instances retain provenance and remain
editable, but edits do not propagate to other instances or back to the preset.
Duplicate Instance creates independent controls. Detach removes provenance while
keeping the content. There are no cross-package references or nested preset
references. A linked component definition/update workflow remains future work.

Save, Save As, undo and crash recovery preserve definitions and instance IDs.
Unused preset assets retain their access scopes and remain in the package.
The scene's existing 64 KiB JSON limit also bounds stored definitions.

## Metadata and posters

Manifest `metadata` supports author, description, tags, license, createdWith and
previewTime. Fields are bounded; previewTime is finite and between 0 and 86400.
Feature requirements replace a loosely comparable minimum-engine string.

+ Create… → Scene Details… edits metadata. Library posters use previewTime
(default 2 seconds), with the existing authored timeline/video-follow semantics.
Revision invalidation, the eight-image RAM cache, and no disk cache remain intact.

## Validation and remaining work

The scene suite covers legacy compatibility, typed defaults and targets, unknown/
missing features, text/shape round trips, independent preset instances and expansion
budgets. GPU smoke tests check actual shape color, visible CoreText glyphs and
deterministic static output. Existing wallpaper, recovery, Library and export
suites exercise the surrounding lifecycle.

Metal remains the creative renderer, with Standard as compatibility for simple
scenes. This work does not establish HDR output or lower energy consumption.
The outstanding promotion gates remain tracked in metal-compositor.md.

The bundled After Hours sample demonstrates editable typography, an accent control,
optional particles and slow geometric motion without media assets. Native UI checks
covered Library selection, controls, preset capture, duplication, insertion and
resetting the temporary draft.
