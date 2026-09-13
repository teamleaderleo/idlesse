import AppKit

/// The offline export pipeline (`scripts/media-batch/ingest.py`), when this Mac
/// has one. Nothing here ships a renderer: the app only starts the script and
/// reads its progress, so every guarantee about cost and replacement lives in
/// one place, the script.
struct MediaPipeline {
    let interpreter: URL
    let script: URL
    let workspace: URL
    /// The PATH the script was last run with. An app launched from the Finder has
    /// a minimal one, without Homebrew's ffmpeg or a user-installed modal.
    let path: String?

    /// `ingest.py` records its paths in the app's defaults on every run. A
    /// development build inside a checkout also finds the checkout's copy, so the
    /// tools are there before anyone has run the script by hand.
    static func discover(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> MediaPipeline? {
        let files = FileManager.default
        if let interpreter = defaults.string(forKey: "IdlessePipelineInterpreter"),
           let script = defaults.string(forKey: "IdlessePipelineScript"),
           let workspace = defaults.string(forKey: "IdlessePipelineWorkspace"),
           files.isExecutableFile(atPath: interpreter), files.fileExists(atPath: script) {
            return MediaPipeline(interpreter: URL(fileURLWithPath: interpreter), script: URL(fileURLWithPath: script),
                                 workspace: URL(fileURLWithPath: workspace), path: defaults.string(forKey: "IdlessePipelinePath"))
        }
        let checkout = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let script = checkout.appendingPathComponent("scripts/media-batch/ingest.py")
        let workspace = checkout.appendingPathComponent("build/ba-export-study")
        let interpreter = workspace.appendingPathComponent(".venv/bin/python")
        guard files.fileExists(atPath: script.path), files.isExecutableFile(atPath: interpreter.path) else { return nil }
        return MediaPipeline(interpreter: interpreter, script: script, workspace: workspace, path: nil)
    }

    /// Whether `media` came out of the pipeline and can be rendered again.
    static func receipt(for media: URL) -> [String: Any]? {
        let url = media.deletingPathExtension().appendingPathExtension("source.json")
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["asset"] is String, object["animation"] is String else { return nil }
        return object
    }

    func run(_ arguments: [String]) -> PipelineRun {
        PipelineRun(pipeline: self, arguments: arguments + ["--workspace", workspace.path])
    }
}

/// One invocation of the pipeline: its latest line, its JSON events, and how it ended.
final class PipelineRun {
    var onLine: ((String) -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    /// Success, and the tail of the output for an error message.
    var onExit: ((Bool, String) -> Void)?
    private let process = Process()
    private let buffer = Buffer()
    private(set) var stopped = false
    var isRunning: Bool { process.isRunning }

    fileprivate init(pipeline: MediaPipeline, arguments: [String]) {
        process.executableURL = pipeline.interpreter
        process.arguments = ["-u", pipeline.script.path] + arguments
        process.currentDirectoryURL = pipeline.workspace
        var environment = ProcessInfo.processInfo.environment
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [pipeline.path, environment["PATH"], fallback].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
        process.environment = environment
    }

    func start() throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = self.buffer
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = buffer.append(data)
            DispatchQueue.main.async { self?.deliver(lines) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let tail = buffer.append(rest) + buffer.flush()
            DispatchQueue.main.async {
                guard let self else { return }
                self.deliver(tail)
                self.onExit?(finished.terminationReason == .exit && finished.terminationStatus == 0 && !self.stopped, buffer.text)
            }
        }
        try process.run()
    }

    private func deliver(_ lines: [String]) {
        for line in lines {
            if line.hasPrefix("IDLESSE "), let data = line.dropFirst(8).data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                onEvent?(event)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                onLine?(line)
            }
        }
    }

    func stop() {
        guard process.isRunning else { return }
        stopped = true
        process.terminate()
    }

    /// Output collected on the reading thread, handed back as whole lines.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var all = Data()
        private var pending = Data()
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: all, as: UTF8.self) }
        func flush() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let line = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            return line.isEmpty ? [] : [line]
        }
        func append(_ chunk: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            all.append(chunk)
            if all.count > 256_000 { all.removeFirst(all.count - 256_000) }
            pending.append(chunk)
            guard let last = pending.lastIndex(of: 0x0A) else { return [] }
            let complete = pending[pending.startIndex...last]
            pending = Data(pending[pending.index(after: last)...])
            return String(decoding: complete, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
    }
}
