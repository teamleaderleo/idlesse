import Foundation

@main struct MediaImportChecks {
    static func main() async throws {
        for path in CommandLine.arguments.dropFirst() {
            let source = URL(fileURLWithPath: path)
            let original = try Data(contentsOf: source)
            let converted = try await MediaImport.convert(source)
            defer { try? FileManager.default.removeItem(at: converted) }
            guard converted.pathExtension == "mp4", FileManager.default.fileExists(atPath: converted.path),
                  try Data(contentsOf: source) == original else { fatalError("Conversion changed the source or failed") }
            guard try await MediaImport.convert(source) == converted else { fatalError("Identical import did not reuse its derivative") }
        }
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID()).webm")
        try Data("invalid media".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        do { _ = try await MediaImport.convert(bad); fatalError("Invalid media accepted") }
        catch { guard FileManager.default.fileExists(atPath: bad.path) else { fatalError("Failed conversion deleted source") } }
        let cancelled = Task { try await MediaImport.convert(bad) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled import completed") }
        catch is CancellationError {} catch { fatalError("Cancellation did not propagate") }
        print("Media import passed: GIF/WebM, preserved originals, cache reuse, invalid media, cancellation")
    }
}
