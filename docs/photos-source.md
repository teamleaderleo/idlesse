# Photos source plan

Idlesse should support a Photos library or album without treating the Photos library package as a folder on disk.

## Supported Apple path

Use PhotoKit:

- `PHPhotoLibrary.authorizationStatus(for: .readWrite)` and `requestAuthorization(for:handler:)` for user permission.
- `PHAssetCollection` to enumerate user-created and smart albums.
- `PHAsset.fetchAssets(in:options:)` to retrieve the images in a selected album.
- `PHImageManager` to request display-quality image data. A `PHAsset` is metadata only, and its underlying image may live in iCloud rather than on local disk.
- `NSPhotoLibraryUsageDescription` in the bundle Info.plist before any read access is attempted.

Apple recommends asking for Photos access in response to an explicit user action instead of at app launch. Idlesse therefore exposes **Connect Photos…** in Options and requests permission there.

## Current proof

The preview app and `.saver` now link PhotoKit and carry a photo-library usage description. The Options panel can:

1. report the current PhotoKit authorization state without prompting;
2. request permission only when **Connect Photos…** is clicked;
3. after authorization, fetch user and smart album collections and report how many are visible.

The next hands-on test is important: run the probe once in **Idlesse Preview**, then install the saver and try the same action from System Settings. The second test tells us whether macOS 26's legacy screen-saver host gives the saver a useful TCC/PhotoKit identity.

## Why the eventual source pipeline is asynchronous

The existing folder source is synchronous: it resolves file URLs and `NSImage` opens them directly. PhotoKit image delivery may be asynchronous and may require an iCloud download. Forcing it through the file-URL path would create stalls and unreliable transitions.

The clean architecture is a small image-provider abstraction shared by the slideshow engine:

1. Folder provider: security-scoped URL, live scan, file metadata ordering.
2. Photos provider: album local identifier, PhotoKit fetch result, asynchronous image requests and prefetching.
3. Slideshow: asks the provider for the next image and does not care where the image came from.

## Next steps after the permission proof

1. List album names and persist a selected album local identifier.
2. Request and render the first asset through `PHImageManager`.
3. Introduce async next-image preloading so iCloud-backed assets do not stall a transition.
4. Make Folder and Photos Album first-class source choices in Options.
