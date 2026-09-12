# Ambient Sets actuation and legacy cutover

`AmbientModesController` is the integration seam for Ambient Sets. Before an explicit cutover it keeps the existing day/night and online-mode behavior unchanged. After cutover it keeps location and solar calculation as condition inputs while `AmbientSetResolver` becomes the single decision authority.

## Applying resolved state

A resolved state is applied in four places:

- Library scene targets resolve through the existing Library ID/bookmark path and select wallpaper transiently so automatic changes never replace the user's persisted manual wallpaper.
- Collection targets use the collection's existing ordered/shuffle rotation policy and interval, bounded to 1–1440 minutes.
- desktop Files and Widgets use idempotent `DesktopComfortController` setters;
- dimming uses one idempotent resolved-state setter with the existing 20–98% safety bounds.

Automatic wallpaper selections are transient. A successful user selection remains the Arrangement Default wallpaper, creates a persisted manual hold, and survives automatic intervals ending. Manual Files, Widgets, and dimming changes merge into the same hold. The resolver's captured next-winner boundary remains the expiry; recurring timers never extend it.

The controller arms a one-shot timer from `AmbientExplanation.nextChange`, with wake/time-zone/clock refreshes as recovery inputs.

## Explicit migration

`migrateLegacyToAmbientSets()` builds a bounded proposal from the current legacy settings and then commits it in this priority order:

1. Bedtime;
2. Follow Sun night;
3. collection schedules in their persisted order.

The current desktop state is captured as Arrangement Default before cutover. Legacy collection schedule windows are backed up before being cleared, while collection rotation minutes/shuffle remain available to Ambient actuation. The Bedtime schedule and day/night settings remain stored for recovery, while their independent actuation is disabled by Ambient authority.

Two migrations fail closed:

- configured online condition scenes, because online Ambient conditions are a follow-up;
- Bedtime overlapping collection schedules when no night scene exists, because the old controllers compose those outputs and the one-winner Ambient rule would otherwise change wallpaper behavior silently.

`disableAmbientSets()` restores the backed-up legacy collection schedules and re-enables legacy Bedtime/day-night actuation.

## Compatibility sentinel targets

The runtime uses two reserved scene IDs internally. User-authored sets cannot select them:

- current selection: preserve a manual wallpaper during a hold;
- Arrangement Default: restore the captured manual wallpaper after an automatic set ends.

These are actuation-only compatibility sentinels; the public Ambient Set target model remains Library scene or collection.

## UI seam

The Home destination can consume `ambientSets`, `currentAmbientResolution`, `onAmbientResolutionChanged`, `activateAmbientSet(id:untilResumed:)`, and `resumeAutomaticAmbientSets()` without owning timers or reimplementing precedence.


## Named scene variants

A scene wallpaper target carries an optional requested variant UUID. Legacy targets without it decode as Default. The UUID is part of the target value and therefore survives resolution even while the referenced scene or variant is temporarily unavailable; collection targets continue to inherit each collection item's own scene+variant selection. Runtime application becomes a direct variant-aware wallpaper selection when the #32 host stack is reconciled with this branch.
