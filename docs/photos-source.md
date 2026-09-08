# Photos source plan

Idlesse should support a Photos library or album without treating the Photos library package as a folder on disk.

## Supported Apple path

Use PhotoKit:

- `PHPhotoLibrary.authorizationStatus(for: .readWrite)` and `requestAuthorization(for:handler:)` for user permission.
- `PHAssetCollection` to enumerate user-created and smart albums.
- `PHAsset.fetchAssets(in:options:)` to retrieve the images in a selected album.
- `PHImageManager` to request display-quality image data. A `PHAsset` is metadata only, and its underlying image may live in iCloud rather than on local disk.
- `NSPhotoLibraryUsageDescription` in the bundle Info.plist before any read access is attempted.

Apple recommends asking for Photos access in response to an explicit user action instead of at app launch. Idlesse therefore exposes **Connect Photos…** in the companion app's Settings window and requests permission there.

## Current proof

Idlesse.app and `.saver` link PhotoKit and carry a photo-library usage description. The companion app can:

1. report its current PhotoKit authorization state without prompting;
2. request permission only when **Connect Photos…** is clicked;
3. after authorization, fetch user and smart album collections and report how many are visible.

macOS 26 Tahoe currently fails to present configuration sheets for some third-party legacy `.saver` bundles, including Idlesse on the test machine. That means the old plan of requesting Photos permission from the System Settings Options sheet is no longer a useful compatibility test.

The companion app's Photos authorization is also a different TCC context from the sandboxed `legacyScreenSaver` host. Seeing albums in Idlesse.app therefore does not prove the installed saver can fetch those assets.

## Why the eventual source pipeline is asynchronous

The existing folder source is synchronous: it resolves file URLs and `NSImage` opens them directly. PhotoKit image delivery may be asynchronous and may require an iCloud download. Forcing it through the file-URL path would create stalls and unreliable transitions.

The clean architecture is a small image-provider abstraction shared by the slideshow engine:

1. Folder provider: security-scoped URL, live scan, file metadata ordering.
2. Photos provider: album local identifier, PhotoKit fetch result, asynchronous image requests and prefetching.
3. Slideshow: asks the provider for the next image and does not care where the image came from.

## Next compatibility test

First verify the new companion-app settings path: select a folder in Idlesse.app, save, then launch the installed saver and confirm that the `legacyScreenSaver` process can resolve the shared security-scoped bookmark. That validates the app↔saver shared-store pattern.

After that, test PhotoKit from the saver runtime itself without relying on Tahoe's broken Options button. If the host can obtain/use Photos authorization, proceed with album playback. If it cannot, Photos parity will need a different source-transfer design or may remain unavailable to third-party legacy savers.

## Next steps after the permission proof

1. List album names and persist a selected album local identifier.
2. Request and render the first asset through `PHImageManager`.
3. Introduce async next-image preloading so iCloud-backed assets do not stall a transition.
4. Make Folder and Photos Album first-class source choices in Idlesse.app.
