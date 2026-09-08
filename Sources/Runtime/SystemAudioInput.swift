import Foundation
import CoreAudio

/// One private tap shared by active hosts. Control methods run on the main thread.
final class SystemAudioInput {
    static let shared = SystemAudioInput()
    private var clients = Set<UUID>()
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let captureQueue = DispatchQueue(label: "app.idlesse.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var levels = SceneAudioLevels()
    private var updated: TimeInterval = 0
    private var captureGeneration = 0
    var isCapturing: Bool { device != 0 && ioProc != nil }
    func snapshot() -> SceneAudioLevels {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - updated < 0.5 ? levels : .init()
    }
    func setActive(_ active: Bool, client: UUID) throws {
        precondition(Thread.isMainThread)
        if active {
            guard !clients.contains(client) else { return }
            if clients.isEmpty { try start() }
            clients.insert(client)
        } else {
            clients.remove(client)
            if clients.isEmpty { stop() }
        }
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SceneError.invalid("\(operation) failed (\(status)). Check Idlesse’s System Audio Recording permission in System Settings.") }
    }
    private func start() throws {
        guard #available(macOS 14.2, *) else { throw SceneError.invalid("System audio response needs macOS 14.2 or later.") }
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "Idlesse Audio Response"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the audio tap")
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Reading the audio format")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  (1...2).contains(format.mChannelsPerFrame) else { throw SceneError.invalid("Audio response requires mono or stereo Float32 audio.") }
            var analyzer = try AudioBandAnalyzer(sampleRate: format.mSampleRate)
            lock.lock(); captureGeneration += 1; let generation = captureGeneration; lock.unlock()
            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Idlesse Audio Response",
                kAudioAggregateDeviceUIDKey: "app.idlesse.audio." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                  kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &device), "Creating the audio input")
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, captureQueue) { [weak self] _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, let data = first.mData, first.mNumberChannels > 0 else { return }
                let channels = Int(first.mNumberChannels)
                guard channels <= 2 else { return }
                let samples = data.assumingMemoryBound(to: Float.self)
                var frames = min(8192, Int(first.mDataByteSize) / (4 * channels))
                let second = buffers.count > 1 ? buffers[1] : nil
                let right = second?.mData?.assumingMemoryBound(to: Float.self)
                if let second { frames = min(frames, Int(second.mDataByteSize) / 4) }
                for index in 0..<frames {
                    let l = samples[index * channels]
                    let r = channels == 2 ? samples[index * channels + 1] : right?[index] ?? l
                    analyzer.append(left: l, right: r)
                }
                let value = analyzer.finishBlock()
                // The audio callback never waits for the renderer or retains sample buffers.
                if let self, self.lock.try() {
                    if generation == self.captureGeneration {
                        self.levels = value
                        self.updated = ProcessInfo.processInfo.systemUptime
                    }
                    self.lock.unlock()
                }
            }, "Preparing audio analysis")
            try check(AudioDeviceStart(device, ioProc), "Starting audio response")
        } catch { stop(); throw error }
    }
    private func stop() {
        lock.lock(); captureGeneration += 1; lock.unlock()
        if device != 0 {
            if let ioProc { AudioDeviceStop(device, ioProc); AudioDeviceDestroyIOProcID(device, ioProc) }
            AudioHardwareDestroyAggregateDevice(device)
        }
        ioProc = nil; device = 0
        if tap != 0, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
        tap = 0
        lock.lock(); levels = .init(); updated = 0; lock.unlock()
    }
}

/// A session grant belongs to a host clock, not to a scene file.
final class SceneAudioSession {
    private let id = UUID()
    private weak var clock: SceneClock?
    init(clock: SceneClock, onError: @escaping (String) -> Void) {
        self.clock = clock
        clock.audioLevels = { SystemAudioInput.shared.snapshot() }
        clock.audioActivityChanged = { [weak self, weak clock] active in
            guard let self else { return }
            do { try SystemAudioInput.shared.setActive(active, client: self.id) }
            catch { clock?.audioEnabled = false; onError(error.localizedDescription) }
        }
    }
    deinit {
        clock?.audioActivityChanged = nil
        clock?.audioLevels = { .init() }
        try? SystemAudioInput.shared.setActive(false, client: id)
    }
}
