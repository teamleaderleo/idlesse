import Foundation
import CryptoKit
import AVFoundation

/// Import-only derivatives. Playback never launches a transcoder.
enum MediaImport {
    static let native: Set<String> = ["idlesse", "jpg", "jpeg", "png", "heic", "mp4", "mov"]
    static let stills: Set<String> = ["avif", "tif", "tiff", "bmp", "jp2", "jxl"]
    static let motion: Set<String> = ["webp", "gif", "apng", "mkv", "webm", "avi", "m4v", "mpg", "mpeg", "ts", "mts", "m2ts", "wmv", "flv", "ogv"]
    static func supports(_ url: URL) -> Bool { native.union(stills).union(motion).contains(url.pathExtension.lowercased()) }
    static func needsConversion(_ url: URL) async throws -> Bool {
        let ext = url.pathExtension.lowercased()
        if stills.union(motion).contains(ext) { return true }
        guard ["mp4", "mov"].contains(ext) else { return false }
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let playable = try await AVURLAsset(url: url).load(.isPlayable)
        try Task.checkCancellation()
        return !playable
    }

    static func convert(_ source: URL) async throws -> URL {
        let worker = Worker()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) { try worker.run(source) }.value
        }, onCancel: { worker.cancel() })
    }

    private final class Worker: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
        func run(_ source: URL) throws -> URL {
            let fm = FileManager.default
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let identity = "v1|\(source.standardizedFileURL.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Idlesse/Converted Media")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let image = MediaImport.stills.contains(source.pathExtension.lowercased())
            let ext = image ? "png" : "mp4"
            let output = root.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent.prefix(80))-\(hash.prefix(16)).\(ext)")
            if fm.fileExists(atPath: output.path) { return output }
            let used = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            guard used < 768 * 1024 * 1024 else { throw error("Converted media is near its 1 GB limit. Remove unused converted files before importing more.") }
            guard let executable = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: fm.isExecutableFile(atPath:)) else {
                throw error("This format needs FFmpeg. Install FFmpeg to enable media conversion.")
            }
            let partial = root.appendingPathComponent(".\(UUID().uuidString).\(ext)")
            defer { try? fm.removeItem(at: partial) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            var args = ["-nostdin", "-v", "error", "-threads", "2", "-protocol_whitelist", "file,pipe", "-i", source.path,
                        "-map", "0:v:0", "-an", "-sn", "-dn", "-map_metadata", "-1"]
            if image { args += ["-frames:v", "1", "-c:v", "png"] }
            else { args += ["-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", "libx265", "-preset", "fast", "-x265-params", "pools=2:frame-threads=2", "-crf", "22", "-pix_fmt", "yuv420p", "-tag:v", "hvc1", "-movflags", "+faststart"] }
            args += ["-fs", "268435456", "-n", partial.path]
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            lock.lock()
            if cancelled { lock.unlock(); throw CancellationError() }
            self.process = process
            do { try process.run() } catch { lock.unlock(); throw error }
            lock.unlock()
            process.waitUntilExit()
            lock.lock(); let stopped = cancelled; self.process = nil; lock.unlock()
            if stopped { throw CancellationError() }
            guard process.terminationStatus == 0 else { throw error("The file couldn’t be decoded or converted. Its original has been preserved.") }
            let size = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size < 255 * 1024 * 1024 else { throw error("Conversion exceeds the 256 MB per-file limit. The partial file was discarded.") }
            try fm.moveItem(at: partial, to: output)
            return output
        }
        private func error(_ message: String) -> NSError { NSError(domain: "Idlesse.MediaImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
