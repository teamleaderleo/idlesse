# Runtime custom shader effects

Revision-21 scene packages may declare the `shader-effects` feature for a
bounded custom Metal effect stored in the ordered Effects list. The effect
payload reuses the existing shader source limits and amount range (`0...1`),
and a scene may contain at most four custom effects. Standalone procedural
shader nodes remain separate from texture-sampling effects.

This runtime/compiler slice establishes package validation, feature gating,
round-trip persistence, source limits, and the fixed one-input ABI compiler.
Studio editing and renderer attachment remain separate follow-up work.
