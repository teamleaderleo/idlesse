CodableShims.swift is from Phosphene, revision
8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6, under the included MIT license.

Source: https://github.com/kageroumado/phosphene/blob/8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6/PhospheneExtension/CodableShims.swift

It is used only by the experimental catalog probe to describe the private
WallpaperSettingsViewModels serialization. It is not linked into Idlesse.
The local catalog archive is created from fixed synthetic data, never from an
external archive. The real runtime class is decoded with secure coding enabled.

The experimental `../Surface.swift` remote-context and snapshot adapters were
also informed by `RuntimeHelpers.swift` and the bridging header at the same
Phosphene revision. They require the observed named ivars/instance sizes instead
of guessing offsets. The bundled MIT license also covers this reference.
