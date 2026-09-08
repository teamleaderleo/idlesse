import Foundation
import Photos

final class PhotosProbe {
    static let shared = PhotosProbe()

    private init() {}

    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var actionTitle: String {
        switch authorizationStatus {
        case .notDetermined:
            return "Connect Photos…"
        case .authorized, .limited:
            return "Refresh"
        case .denied, .restricted:
            return "Unavailable"
        @unknown default:
            return "Check Photos"
        }
    }

    var actionEnabled: Bool {
        switch authorizationStatus {
        case .denied, .restricted:
            return false
        default:
            return true
        }
    }

    var statusText: String {
        switch authorizationStatus {
        case .notDetermined:
            return "Not connected"
        case .denied:
            return "Access denied"
        case .restricted:
            return "Access restricted"
        case .authorized:
            return albumSummary(accessLabel: "Connected")
        case .limited:
            return albumSummary(accessLabel: "Limited access")
        @unknown default:
            return "Unknown Photos status"
        }
    }

    func requestAccess(completion: @escaping () -> Void) {
        let status = authorizationStatus

        guard status == .notDetermined else {
            DispatchQueue.main.async(execute: completion)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func albumSummary(accessLabel: String) -> String {
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )
        let count = userAlbums.count + smartAlbums.count
        return "\(accessLabel) · \(count) album collections"
    }
}
