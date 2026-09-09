import AppKit

/// Package-level regression checks through the production loader and Metal pipeline.
/// No windows, input permissions, wallpaper preferences or library state are touched.
@MainActor enum SceneConformance {
    struct Corpus: Decodable { let cases: [Case] }
    struct Case: Decodable {
        let name: String
        let path: String
        let times: [Double]
        let changes: Bool
        let probes: [Probe]
    }
    struct Probe: Decodable {
        let x: Int
        let y: Int
        let rgb: [Int]
        let tolerance: Int
    }

    static func run(_ url: URL) async throws {
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        guard !corpus.cases.isEmpty else { throw SceneError.invalid("Empty conformance corpus") }
        var frames = 0
        for test in corpus.cases {
            guard !test.times.isEmpty, test.times.allSatisfy({ $0.isFinite && (0...86400).contains($0) }),
                  test.probes.allSatisfy({ (0..<64).contains($0.x) && (0..<64).contains($0.y) &&
                      $0.rgb.count == 3 && $0.rgb.allSatisfy({ (0...255).contains($0) }) && (0...8).contains($0.tolerance) }) else {
                throw SceneError.invalid("Invalid conformance case: \(test.name)")
            }
            let scene = try await LocalSceneSource().resolve(url.deletingLastPathComponent().appendingPathComponent(test.path))
            var reference: [[UInt8]] = []
            var peakTargets = 0
            // Recreate resources, then visit times in reverse: catches stale caches and seek history.
            for pass in 0..<2 {
                let clock = SceneClock(now: { 0 })
                try clock.configure(timeline: scene.timeline)
                var errors: [String] = []
                let renderer = try MetalSceneRenderer(playable: scene,
                    bounds: NSRect(x: 0, y: 0, width: 64, height: 64), scale: 1,
                    clock: clock, onError: { errors.append($0) })
                defer { renderer.releaseResources() }
                let indices = pass == 0 ? Array(test.times.indices) : Array(test.times.indices.reversed())
                for index in indices {
                    try clock.seek(to: test.times[index])
                    try await renderer.prepareOfflineVideo(at: clock.time, size: CGSize(width: 64, height: 64))
                    let pixels = try renderer.renderProbe(signals: .init(time: clock.time), dimension: 64)
                    guard errors.isEmpty else { throw SceneError.invalid("\(test.name): \(errors.joined(separator: "; "))") }
                    guard renderer.intermediateTextureBytes <= SceneBudget.intermediateTextureBytes else {
                        throw SceneError.invalid("\(test.name): intermediate texture budget exceeded")
                    }
                    peakTargets = max(peakTargets, renderer.intermediateTextureBytes)
                    if pass == 0 { reference.append(pixels) }
                    else if pixels != reference[index] {
                        throw SceneError.invalid("\(test.name): nondeterministic replay at \(test.times[index])s")
                    }
                    for probe in test.probes {
                        let offset = (probe.y * 64 + probe.x) * 4
                        let actual = [Int(pixels[offset + 2]), Int(pixels[offset + 1]), Int(pixels[offset])]
                        guard zip(actual, probe.rgb).allSatisfy({ abs($0 - $1) <= probe.tolerance }) else {
                            throw SceneError.invalid("\(test.name): pixel (\(probe.x),\(probe.y)) expected \(probe.rgb), got \(actual)")
                        }
                    }
                    frames += 1
                }
            }
            guard reference.contains(where: { pixels in
                stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] > 8 || pixels[$0 + 1] > 8 || pixels[$0 + 2] > 8 }
            }) else { throw SceneError.invalid("\(test.name): entirely black output") }
            if test.changes && !reference.dropFirst().contains(where: { $0 != reference[0] }) {
                throw SceneError.invalid("\(test.name): expected animation, got identical frames")
            }
            print("PASS \(test.name): \(test.times.count * 2) frames; peak intermediate bytes \(peakTargets)")
        }
        print("Conformance passed: \(corpus.cases.count) packages, \(frames) frames, forward/reverse replay, no input grants.")
    }
}
