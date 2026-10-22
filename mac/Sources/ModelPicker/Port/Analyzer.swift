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
    /// There is no time limit and no silence stop: it listens until stop() is called. If the recognizer
    /// ends on its own, a fresh one starts and the words so far are kept.
    func start(onText: @escaping @Sendable (String) -> Void, useMic: Bool = true) async throws {
        let t = try await Self.makeTranscriber()
        let input = engine.inputNode
        let natural = useMic ? input.outputFormat(forBus: 0) : AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw NSError(domain: "ModelPicker", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"]) }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t], considering: natural) else { throw NSError(domain: "ModelPicker", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio format"]) }
        SpeechInput.log("analyzer: mic \(natural) -> \(fmt)")
        inFmt = natural; outFmt = fmt
        converter = fmt == natural ? nil : AVAudioConverter(from: natural, to: fmt)
        finalText = ""; volatile = ""; stopping = false; restarts = 0
        self.onText = onText
        try await startSession(t)
        buffers = 0
        guard useMic else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: natural) { [weak self] buf, _ in self?.feed(buf) }
        engine.prepare()
        try engine.start()
        // If macOS changes the audio device mid-talk (AirPods, sleep, etc.) the engine stops by itself. Restart it.
        configObs = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, !self.stopping else { return }
            SpeechInput.log("analyzer: audio device changed, restarting mic")
            self.engine.inputNode.removeTap(onBus: 0)
            let nat = self.engine.inputNode.outputFormat(forBus: 0)
            guard nat.sampleRate > 0, let o = self.outFmt else { return }
            self.lock.lock(); self.inFmt = nat; self.converter = nat == o ? nil : AVAudioConverter(from: nat, to: o); self.lock.unlock()
            self.engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nat) { [weak self] b, _ in self?.feed(b) }
            self.engine.prepare(); do { try self.engine.start() } catch { SpeechInput.log("analyzer: mic restart failed \(error)") }
        }
    }

    private var onText: (@Sendable (String) -> Void)?
    private var volatile = ""
    private var stopping = false
    private(set) var restarts = 0
    private var session = 0
    private let lock = NSLock()

    /// One recognizer run. Audio keeps flowing into whichever run is current.
    private func startSession(_ given: SpeechTranscriber? = nil) async throws {
        let t: SpeechTranscriber
        if let given { t = given } else { t = try await Self.makeTranscriber() }
        let (stream, c) = AsyncStream<AnalyzerInput>.makeStream()
        let a = SpeechAnalyzer(modules: [t])
        session += 1; let mine = session
        resultsTask = Task { [weak self] in
            do {
                for try await r in t.results {
                    guard let self else { return }
                    let piece = String(r.text.characters)
                    if r.isFinal { self.finalText = Self.join(self.finalText, piece); self.volatile = ""; self.onText?(self.finalText) }
                    else { self.volatile = piece; self.onText?(Self.join(self.finalText, piece)) }
                }
            } catch { SpeechInput.log("analyzer results error: \(error)") }
            guard let self, !self.stopping, self.session == mine else { return }
            // Ended without the user stopping: keep what we heard and start a fresh recognizer.
            self.finalText = Self.join(self.finalText, self.volatile); self.volatile = ""
            self.restarts += 1
            SpeechInput.log("analyzer: recognizer ended on its own, restart #\(self.restarts)")
            self.lock.withLock { self.cont = nil }
            guard self.restarts <= 50 else { SpeechInput.log("analyzer: too many restarts, giving up"); return }
            do { try await self.startSession() } catch { SpeechInput.log("analyzer: restart failed \(error)") }
        }
        try await a.start(inputSequence: stream)
        let held = lock.withLock { () -> [AnalyzerInput] in analyzer = a; cont = c; let h = pending; pending = []; return h }
        for b in held { c.yield(b) }
    }
    private var pending: [AnalyzerInput] = []
    var simulated = false

    /// Test hook: make the current recognizer quit by itself, as if the system ended it.
    func simulateEnd() async { let (a, c) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?) in let r = (analyzer, cont); cont = nil; return r }; c?.finish(); await a?.cancelAndFinishNow() }

    private var inFmt: AVAudioFormat?
    private var outFmt: AVAudioFormat?
    private var configObs: NSObjectProtocol?

    /// Final pieces from SpeechTranscriber don't always carry a leading space; never glue two words together.
    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }; if b.isEmpty { return a }
        if a.last!.isWhitespace || b.first!.isWhitespace { return a + b }
        return a + " " + b
    }

    /// Hand one buffer of audio (in the mic's format) to the recognizer.
    func feed(_ buf: AVAudioPCMBuffer) {
        lock.lock(); let c = cont; let fmt = outFmt; let natural = inFmt; let conv = converter; let stop = stopping; lock.unlock()
        guard !stop, let fmt, let natural else { return }
        buffers += 1
        var item: AnalyzerInput?
        if let conv {
            let ratio = fmt.sampleRate / natural.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64) else { return }
            var fed = false; var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf }
            if err == nil, out.frameLength > 0 { item = AnalyzerInput(buffer: out) }
        } else { item = AnalyzerInput(buffer: buf) }
        guard let item else { return }
        if let c { c.yield(item) } else { lock.lock(); if pending.count < 400 { pending.append(item) }; lock.unlock() }  // between recognizers: hold the audio
    }

    /// Self-test: play a file through the exact live path in real time, as if it came from the mic.
    /// Writes every text update the chat box would get.
    static func liveFile(_ path: String, endAt: Double? = nil) async -> String {
        do {
            let lt = LiveTranscriber()
            let events = EventLog()
            try await lt.start(onText: { events.add($0) }, useMic: false)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let f48 = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            while file.framePosition < file.length {
                guard let b = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: 4096) else { break }
                try file.read(into: b, frameCount: 4096)
                if b.frameLength == 0 { break }
                lt.feed(b)
                if let e = endAt, Double(file.framePosition) / 48000 >= e, lt.restarts == 0, !lt.simulated { lt.simulated = true; await lt.simulateEnd() }
                try await Task.sleep(nanoseconds: UInt64(Double(b.frameLength) / 48000 * 1e9))
            }
            let final = await lt.stop()
            return "restarts=\(lt.restarts) " + events.report(final: final)
        } catch { return "ERROR: \(error)" }
    }

    /// Stop the mic and wait for the last words. Returns the final text.
    func stop() async -> String {
        stopping = true
        if let o = configObs { NotificationCenter.default.removeObserver(o); configObs = nil }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        let c = lock.withLock { () -> AsyncStream<AnalyzerInput>.Continuation? in let x = cont; cont = nil; return x }; c?.finish()
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch { SpeechInput.log("analyzer finish error: \(error)") }
        _ = await resultsTask?.value
        finalText = Self.join(finalText, volatile); volatile = ""
        analyzer = nil; resultsTask = nil
        SpeechInput.log("analyzer: stop buffers=\(buffers) text='\(finalText)'")
        return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class EventLog: @unchecked Sendable {
    private let q = DispatchQueue(label: "events"); private var all: [(Date, String)] = []; private let t0 = Date()
    func add(_ s: String) { q.sync { all.append((Date(), s)) } }
    func report(final: String) -> String {
        q.sync {
            var shrank = 0; var prev = ""
            for (_, s) in all { if s.count + 5 < prev.count { shrank += 1 }; prev = s }
            let words = final.split(separator: " ").count
            let tail = all.suffix(6).map { String(format: "%.1fs ", $0.0.timeIntervalSince(t0)) + "'\($0.1.suffix(60))'" }.joined(separator: "\n")
            return "updates=\(all.count) shrinks=\(shrank) finalWords=\(words)\nlast updates:\n\(tail)\nFINAL: \(final)"
        }
    }
}
