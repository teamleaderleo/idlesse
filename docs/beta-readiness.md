# Beta readiness

Owner: Idlesse development. Target: a reproducible, notarized beta with no
unqualified color or performance claims. Revision 21 remains the format baseline.

## Implemented in this pass

- Successful wallpaper selections and pause state persist through normal quit.
  Explicit Stop clears restart state; CLI test controllers do not persist it.
- Help > Copy Diagnostics: local, redacted system/display and playback counts.
- Library remains the first-launch front door; no extra setup wizard.
- Versioned local/Developer ID packaging script and install/uninstall instructions.

## Gates still open

- Developer ID certificate and notarytool profile (not available on this Mac).
- Actual notarization, clean install on another account/Mac, Finder activation.
- HDR input: current policy is SDR; HDR normalization remains unqualified.
- Multi-hour two-display rotation/crossfade soak and matched energy comparison.
- Physical display disconnect/reconnect and actual sleep/wake checks.
- Broader diagnostics: permission state, renderer memory and installed saver state.

Do not infer physical hotplug or energy results from simulated lifecycle tests.
Do not promote Metal or call a local artifact notarized.

## Packaging

`VERSION=0.1.0 BUILD_NUMBER=2 scripts/package-beta.sh local`

For a configured release machine, use `notarized` with SIGN_IDENTITY set to its
Developer ID Application identity and NOTARY_PROFILE set to a Keychain profile.
The script signs the extension before its host, verifies, submits, staples,
and assesses the app. Build numbers must advance; existing artifacts are not
overwritten. Credentials are not stored in the repository.

Next: execute persistence regression checks and packaging locally, then close
HDR/lifecycle/energy gates before distributing externally. Wallpaper Engine
translation and linked components follow the beta qualification work.

## Local verification — 2026-09-10

- Built local 0.1.0 (2) archive; app, extension and saver signature checks passed.
- Installed the app extracted from that archive, then quit/reopened: Ichika
  resumed automatically on both displays. Help > Copy Diagnostics verified.
- Wallpaper, Library, HEVC export/cancellation and isolated restart tests passed.
- Scene conformance: 15 packages, 120 frames, forward/reverse replay passed.
- Diagnostic display dimensions describe the current macOS render mode, not
  physical panel resolution. Scaled 4K panels may report 5120×2880 render pixels.
- No public notarization, HDR, multi-hour soak, energy or physical hotplug claim.
