# Installed Options recovery — 2026-09-08

Reproduced an inert Options button in System Settings. No configureSheet event
was logged for the failed click. The installed saver binary differed from the
current build and its long-lived host was running the older standalone-settings
implementation. Building and pushing had not updated that installed bundle.

Recovery: quit System Settings, build the current release saver, replace the
installed bundle, verify its signature, restart legacyScreenSaver, and reopen
System Settings. The current native configureSheet implementation then worked.
No fallback panel or presentation workaround was reintroduced.

Verified through native UI automation: Options shows all controls; Cancel returns
to the chooser; Options reopens; Save without edits returns to the chooser. A third
Options click logged configureSheet attached by host with settingsVisible=true.
After reconnecting UI automation, the third Options sheet was independently
confirmed with all controls visible. The host remained running.

`./build.sh installed-status` now compares the installed binary with the local
build and checks its signature. Equality does not prove a running host has loaded
that binary. `--smoke-options` validates the constructed app UI, not the installed
System Settings Options route; these are separate checks.
