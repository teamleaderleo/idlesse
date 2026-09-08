# Photos source plan

Idlesse should support a Photos library or album without treating the Photos library package as a folder on disk.

## Supported Apple path

Use PhotoKit:

- `PHPhotoLibrary.authorizationStatus(for: .readWrite)` and `requestAuthorization(for:handler:)` for user permission.
- `PHAssetCollection` to enumerate user-created and smart albums.
- `PHAsset.fetchAssets(in:options:)` to retrieve the images in a selected album.
- `PHImageManager` to request display-quality image data. A `PHAsset` is metadata only, and its underlying image may live in iCloud rather than on local disk.
- `NSPhotoLibraryUsageDescription` in the bundle Info.plist before any read access is attempted.

Apple recommends asking for Photos access in response to an explicit user action instead of at app launch. Idlesse should therefore expose a **Connect Photos…** action in Options and request permission there.

## Why this is a separate source pipeline

The existing folder source is synchronous: it resolves file URLs and `NSImage` opens them directly. PhotoKit image delivery may be asynchronous and may require an iCloud download. Forcing it through the file-URL path would create stalls and unreliable transitions.

The clean architecture is a small image-provider abstraction shared by the slideshow engine:

1. Folder provider: security-scoped URL, live scan, file metadata ordering.
2. Photos provider: album local identifier, PhotoKit fetch result, asynchronous image requests and prefetching.
3. Slideshow: asks the provider for the next image and does not care where the image came from.

## Proof sequence

1. Add PhotoKit and `NSPhotoLibraryUsageDescription` to the standalone preview app.
2. Add a user-triggered **Connect Photos…** flow and list albums.
3. Select an album and render its first image in the preview app.
4. Verify the same authorization/fetch path from the installed `.saver` on macOS 26, because the system screen-saver host is the compatibility boundary that matters.
5. Once host behavior is confirmed, add async preloading and make Photos a first-class source beside Folder.

The permission proof comes before a large provider refactor so we learn what macOS 26 actually allows inside the legacy screen-saver host.
