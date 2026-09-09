import AppKit
import AVFoundation

/// A bounded, silent export of the authored scene. No desktop windows or input grants.
@MainActor enum SceneVideoExporter {
    static func smokeTest(videoURL: URL) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IdlesseExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = SceneDescriptor(title: "Video", assetURL: videoURL, kind: .video)
        let output = folder.appendingPathComponent("complete.mp4")
        try await export(scene, to: output, width: 64, height: 64, fps: 30, duration: 0.2, progress: { _ in })
        let original = try Data(contentsOf: output)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        precondition(tracks.count == 1)
        let reader = try AVAssetReader(asset: asset)
        let track = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(track); precondition(reader.startReading())
        var frames = 0
        while track.copyNextSampleBuffer() != nil { frames += 1 }
        precondition(reader.status == .completed && frames == 6, "Offline export must write exactly the requested frames")
        do {
            try await export(scene, to: output, width: 64, height: 64, fps: 30, duration: 0.2, progress: { _ in })
            preconditionFailure("Overwrote an existing movie")
        } catch is SceneError {}
        let unchanged = try Data(contentsOf: output); precondition(unchanged == original)
        var task: Task<Void, Error>?
        task = Task { @MainActor in
            try await export(scene, to: folder.appendingPathComponent("cancelled.mp4"), width: 64, height: 64,
                fps: 30, duration: 2) { _ in task?.cancel() }
        }
        do { try await task!.value; preconditionFailure("Ignored export cancellation") }
        catch is CancellationError {}
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(remaining == ["complete.mp4"], "Cancellation must remove partial output")
        print("Export checks passed: decoded video frames, HEVC frame count, overwrite protection, cancellation and partial-file cleanup")
    }

    static func export(_ scene: SceneDescriptor, to destination: URL, width: Int, height: Int,
                       fps: Int, duration: Double, progress: @escaping (Double) -> Void) async throws {
        guard [30, 60].contains(fps), duration.isFinite, (0.1...60).contains(duration),
              (32...3840).contains(width), (32...2160).contains(height), width % 2 == 0, height % 2 == 0 else {
            throw SceneError.invalid("Export supports up to 4K, 30/60 fps and 0.1–60 seconds.")
        }
        let files = FileManager.default
        // Write beside the destination and publish only a completed movie; never destroy an existing file.
        guard !files.fileExists(atPath: destination.path) else { throw SceneError.invalid("Choose a new filename for the exported movie.") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".idlesse-export-\(UUID().uuidString).mp4")
        defer { try? files.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false, AVVideoAverageBitRateKey: max(2_000_000, width * height * fps / 8)],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw SceneError.invalid("HEVC export is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SceneError.invalid("Could not start video export.") }
        writer.startSession(atSourceTime: .zero)
        var completed = false
        defer { if !completed { writer.cancelWriting() } }
        var instant = 0.0
        let clock = SceneClock(now: { instant })
        try clock.configure(timeline: scene.timeline)
        clock.setPaused(false)
        let renderer = try MetalSceneRenderer(playable: scene, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                              scale: 1, clock: clock, onError: { _ in })
        defer { renderer.releaseResources() }
        let frameCount = Int(ceil(duration * Double(fps)))
        for index in 0..<frameCount {
            try Task.checkCancellation()
            instant = Double(index) / Double(fps)
            let waitStart = ProcessInfo.processInfo.systemUptime
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing, ProcessInfo.processInfo.systemUptime - waitStart < 30 else {
                    throw writer.error ?? SceneError.invalid("The video encoder stopped responding.")
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await renderer.prepareOfflineVideo(at: scene.timeline?.videosFollowScene == true ? clock.time : instant,
                                                    size: CGSize(width: width, height: height))
            let bytes = try renderer.renderFrame(signals: SceneSignals(time: clock.time), width: width, height: height, sampleVideo: false)
            guard let pool = adaptor.pixelBufferPool else { throw SceneError.invalid("Missing export pixel pool.") }
            var optional: CVPixelBuffer?
            let attributes = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
            let allocationStart = ProcessInfo.processInfo.systemUptime
            while optional == nil {
                let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, attributes, &optional)
                if status == kCVReturnSuccess { break }
                guard status == kCVReturnWouldExceedAllocationThreshold, writer.status == .writing,
                      ProcessInfo.processInfo.systemUptime - allocationStart < 30 else {
                    throw writer.error ?? SceneError.invalid("The video encoder could not release a frame within its buffer budget.")
                }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let buffer = optional else { throw SceneError.invalid("Missing export frame buffer.") }
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                bytes.withUnsafeBytes { source in
                    for row in 0..<height { memcpy(base.advanced(by: row * stride), source.baseAddress!.advanced(by: row * width * 4), width * 4) }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: Int32(fps))) else {
                throw writer.error ?? SceneError.invalid("Could not append the exported frame.")
            }
            progress(Double(index + 1) / Double(frameCount))
            await Task.yield()
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: Int32(fps)))
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? SceneError.invalid("Could not finish video export.") }
        try files.moveItem(at: temporary, to: destination)
        completed = true
    }
}
