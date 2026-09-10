# Azur Lane intake

One command inventories only Azur Lane's game asset folder, pulls the explicitly selected skins, compares SHA-256 hashes against the device, and reports textures, animation clip names and physics assets:

```sh
build/ba-export-study/.venv/bin/python scripts/azur-lane/intake.py \
  --serial '<serial from adb devices>' \
  --output build/azur-lane-study --inspect
```

Requires an already-authorized Android with the installed game's Live2D resources downloaded. Uses `adb`; `--inspect` additionally requires UnityPy. It never changes device settings, installs an APK or scans unrelated app data. It stops if source files changed and preserves existing downloads. Successful files are hash-checked and skipped on resume. Bundles above 64 MiB are refused for deliberate review. A partial transfer can be retried.

Edit `candidates.json` to choose known asset names/titles; do not bulk-download every skin. The current sample plan contains Belfast, Atago and Ägir. Files live only under the requested build directory and are not committed.

This automates source intake and inspection. Unity component → Cubism model/motion reconstruction and a deterministic Live2D export backend are still required; the current Blue Archive Spine renderer cannot decode `.moc3`.
