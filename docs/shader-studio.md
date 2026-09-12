# Shader Studio authoring

Track C of issue #28 adds native shader source authoring to Studio while keeping the revision 21 container and existing scene/control model unchanged.

## Current workflow

- Shader source and the existing `speed` value are editable in the persistent layer inspector.
- **Compile** validates the existing shader budget and asks Metal to compile a probe pipeline using the runtime `V` / `ShaderU` interface. A `#line` directive maps compiler diagnostics back to snippet line numbers.
- **Apply** compiles first, then commits through Studio's ordinary node edit path so undo/redo and recovery keep working. Invalid drafts remain local and the active renderer keeps the last valid shader.
- Built-in templates are small starting points only: Plasma, Soft Rings, Pointer Glow, and Drifting Grid.
- Shader source and speed round-trip through revision 21 package read/write. The manifest feature vocabulary and current runtime validation/budgets stay unchanged.

## Remaining rough edges

- The source editor has native text undo/find and compiler line diagnostics, but no syntax highlighting, gutter line numbers, or code completion yet.
- Switching layers discards an un-applied shader draft; Apply is the persistence boundary.
- The existing 64 KB `scene.json` package limit still applies to aggregate authored content, so several shader layers near the per-shader 32 KB ceiling can exceed the package budget on save.
- Templates are editor conveniences, not reusable package presets. Broader shader controls and reusable preset work belongs to #41 and should use the existing typed scene-control model.
- Metal can occasionally attach diagnostics to generated/probe source. Those lines are preserved verbatim when they cannot be mapped to the authored snippet.

✨ Kira
