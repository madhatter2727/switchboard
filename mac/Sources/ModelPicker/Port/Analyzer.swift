import AVFoundation
import Speech

/// macOS 26 on-device speech (SpeechAnalyzer + SpeechTranscriber). Unlike SFSpeechRecognizer it does not
/// need Siri/Dictation turned on. Audio never leaves this Mac.
@available(macOS 26.0, *)
final class LiveTranscriber: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var cont: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var finalText = ""
    private(set) var buffers = 0

    static func makeTranscriber() async throws -> SpeechTranscriber {
        let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        // The speech model is shared by the system, but each app must reserve its language first.
        if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier == loc.identifier }) {
            do { let ok = try await AssetInventory.reserve(locale: loc); SpeechInput.log("analyzer: reserve \(loc.identifier) -> \(ok)") } catch { SpeechInput.log("analyzer: reserve error \(error)") }
        }
        let st = await AssetInventory.status(forModules: [t])
        SpeechInput.log("analyzer: locale \(loc.identifier) asset status \(st)")
        if st == .unsupported { throw NSError(domain: "ModelPicker", code: 3, userInfo: [NSLocalizedDescriptionKey: "On-device speech isn't supported for \(loc.identifier)."]) }
        if st != .installed, let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            SpeechInput.log("analyzer: downloading speech model for \(loc.identifier)…")
            try await req.downloadAndInstall()
        }
        return t
    }

    /// Transcribe a whole audio file (used by the self-test).
    static func transcribeFile(_ path: String) async -> String {
        do {
            let t = try await makeTranscriber()
            let a = SpeechAnalyzer(modules: [t])
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let collect = Task { () -> String in
                var s = ""; do { for try await r in t.results where r.isFinal { s += String(r.text.characters) } } catch { s += " [results error: \(error)]" }; return s }
            if let last = try await a.analyzeSequence(from: file) { try await a.finalizeAndFinish(through: last) } else { await a.cancelAndFinishNow() }
            return await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return "ERROR: \(error)" }
    }

    /// Start the mic. onText gets the full text so far (final + in-progress words).
    func start(onText: @escaping @Sendable (String) -> Void) async throws {
        let t = try await Self.makeTranscriber()
        let input = engine.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw NSError(domain: "ModelPicker", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"]) }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t], considering: natural) else { throw NSError(domain: "ModelPicker", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio format"]) }
        SpeechInput.log("analyzer: mic \(natural) -> \(fmt)")
        converter = fmt == natural ? nil : AVAudioConverter(from: natural, to: fmt)
        let (stream, c) = AsyncStream<AnalyzerInput>.makeStream(); cont = c
        let a = SpeechAnalyzer(modules: [t]); analyzer = a
        finalText = ""
        resultsTask = Task { [weak self] in
            do {
                for try await r in t.results {
                    guard let self else { return }
                    let piece = String(r.text.characters)
                    if r.isFinal { self.finalText += piece; onText(self.finalText) } else { onText(self.finalText + piece) }
                }
            } catch { SpeechInput.log("analyzer results error: \(error)") }
        }
        try await a.start(inputSequence: stream)
        buffers = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: natural) { [weak self] buf, _ in
            guard let self else { return }
            self.buffers += 1
            if let conv = self.converter {
                let ratio = fmt.sampleRate / natural.sampleRate
                guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64) else { return }
                var fed = false; var err: NSError?
                conv.convert(to: out, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buf }
                if err == nil, out.frameLength > 0 { c.yield(AnalyzerInput(buffer: out)) }
            } else { c.yield(AnalyzerInput(buffer: buf)) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stop the mic and wait for the last words. Returns the final text.
    func stop() async -> String {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        cont?.finish(); cont = nil
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch { SpeechInput.log("analyzer finish error: \(error)") }
        _ = await resultsTask?.value
        analyzer = nil; resultsTask = nil
        SpeechInput.log("analyzer: stop buffers=\(buffers) text='\(finalText)'")
        return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
