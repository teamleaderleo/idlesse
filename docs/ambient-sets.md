# Ambient Sets core

Ambient Sets resolve a small list of named, sparse desktop-state overrides into one `ResolvedDesktopState`. The resolver has one authority rule:

`Manual Hold → first matching Ambient Set → Arrangement Default`

The core is UI-independent so Home/Displays can consume the same answer as wallpaper, dimming, desktop-files, and desktop-widgets actuation.

## Model and limits

An Ambient Set can override a Library scene or collection target, desktop Files visibility, desktop Widgets visibility, and visual dimming. Missing fields inherit the Arrangement Default. Automatic conditions are deliberately small: local time range, weekdays, and solar night (sunset through the following sunrise). Conditions inside one set are ANDed. A set with no activation is Manual Only.

Priority is the persisted list order. At most 128 sets are evaluated, identifiers are capped at 256 characters, names at 80 characters, boundary search at 4,096 candidates over eight days, and the persisted catalog at 1 MiB. These bounds keep timer-driven resolution predictable.

For overnight time ranges, a weekday names the day the interval starts. `Friday 22:00–07:00` therefore continues through Saturday 07:00, matching the current collection-schedule convention.

## Manual hold and next change

Manual activation creates an `AmbientManualHold`. The default policy captures the next point where the winning automatic set changes and stores that exact timestamp. Re-evaluation, location refreshes, and unrelated condition updates reuse that timestamp. `untilResumed` provides an explicit indefinite hold.

`AmbientExplanation` reports the decision source, active set, matching reasons, lower-priority sets that also matched, and the next winning-set change. UI can render this directly as an Ambient Sets state chip or detail row.

Solar event calculation is injected through `SolarProvider`; the existing location/NOAA code can report events without gaining decision authority.

## Persistence and migration

`AmbientSetStore` persists ordered sets plus any active manual hold atomically. It rejects oversized catalogs, duplicate IDs, invalid sets, and invalid holds.

`AmbientLegacyAdapter` provides explicit conversion inputs for:

- collection schedules → collection-target Ambient Set with the same time/weekdays;
- Follow Sun night behavior → a solar-night set;
- Bedtime → a time-range set with dimming and an optional night scene.

Migration is opt-in. Existing collection schedules, day/night behavior, and Bedtime continue running until the caller commits the generated Ambient Sets catalog. At that cutover the integration layer must stop those legacy controllers from independently changing wallpaper/dimming, while retaining their condition-source calculations where useful.

## Actuation seam

Consumers should apply only the resolved output:

- wallpaper/display code applies `ResolvedDesktopState.wallpaper`;
- desktop visibility applies `filesVisible` / `widgetsVisible`;
- dimming applies `dimming`;
- the resolver alone chooses the winning Ambient Set.

Display-arrangement assignment plans from #31 can replace the current scene/collection target with a richer target later without changing precedence or condition evaluation.
