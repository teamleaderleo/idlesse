# Scene conformance fixtures

Run `BUILD_DIR="$PWD/build/qualification" ./test-conformance.sh` after an optimized
app build. Paths in `corpus.json` are relative to that file. Additional local
corpora can reference raw videos without copying their media into the repository.

The tagged image fixtures are original 32×32 PNGs generated with Core Graphics.
Both represent sRGB RGB (64,128,192): `tagged-srgb` stores that color in sRGB;
`tagged-display-p3` converts it to Display P3 with relative-colorimetric intent
before storing pixels and the embedded color profile. Their shared output probe
checks conversion back into the compositor's SDR space within two code values.
This is an in-gamut profile-conversion test, not an HDR or out-of-gamut clipping
test. The files and synthetic scene descriptions are CC0-1.0.

The blend expectations are independently calculated from the encoded-channel
premultiplied blend equations. Nested opacity expects 255 × 0.5 × 0.5 ≈ 64.
Do not substitute captured output for these analytic expectations.
