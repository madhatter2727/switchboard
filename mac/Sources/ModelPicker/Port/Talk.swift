import AVFoundation
import Speech
import WebKit

/// Nov 13 (Tara's notes, item 2): hands-free Talk mode, listening side.
/// Uses the same on-device recognizer as the mic button (macOS 26 SpeechAnalyzer + SpeechTranscriber,
/// en-US model already installed; nothing is downloaded or sent to the cloud). The page decides when the
/// user has finished (a short pause with no new words) and calls talkStop to get the final text.
/// Test hook: talkStart with "file" feeds a 48 kHz mono audio file through the exact same feed() path in
/// real time (then 2 s of silence), instead of the microphone.
final class Talk: @unchecked Sendable {
    static let shared = Talk()
    private let lock = NSLock()
    private var live: AnyObject?
    private var feeder: Task<Void, Never>?
    private var session = 0

    static func push(_ obj: [String: Any]) {
        let j = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        DispatchQueue.main.async { MainActor.assumeIsolated { for p in Speech.shared.pages { p()?.evaluateJavaScript("window.__talk && window.__talk(\(j))", completionHandler: nil) } } }
    }
    static func wait<T>(_ f: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0); var out: T?
        Task.detached { out = await f(); sem.signal() }
        sem.wait(); return out!
    }

    func start(file: String?) -> [String: Any] {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return ["ok": false, "error": "Talk mode needs the on-device speech recognizer in macOS 26."] }
        _ = Self.wait { await self.stopNow() }   // never two listeners
        if file == nil {
            let st = AVCaptureDevice.authorizationStatus(for: .audio)
            if st == .denied || st == .restricted { return ["ok": false, "error": "Microphone access is off for Switchboard. Turn it on in System Settings > Privacy & Security > Microphone."] }
            if st == .notDetermined {
                let ok = Self.wait { await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } } }
                if !ok { return ["ok": false, "error": "Microphone access was not allowed."] }
            }
        }
        let mine: Int = lock.withLock { session += 1; return session }
        return Self.wait { () -> [String: Any] in
            let lt = LiveTranscriber()
            // Pause detector: once there has been voice, ~1.2 s of quiet tells the page the turn is over, even when
            // the recognizer hasn't shown any words yet (short answers like "stop" often only appear when it finishes).
            let vad = VAD()
            lt.levelHook = { rms, secs in if vad.step(rms: rms, secs: secs) { Talk.push(["session": mine, "endOfSpeech": true]) } }
            do {
                try await lt.start(onText: { t in Talk.push(["session": mine, "text": t, "listening": true]) }, useMic: file == nil)
            } catch {
                SpeechInput.log("talk: start failed \(error)")
                return ["ok": false, "error": "Listening didn't start (\(error.localizedDescription))."]
            }
            self.lock.withLock { self.live = lt }
            SpeechInput.log("talk: listening session \(mine)" + (file != nil ? " (test file)" : ""))
            if let f = file { self.lock.withLock { self.feeder = Task.detached { await Self.feedFile(lt, f) } } }
            Talk.push(["session": mine, "text": "", "listening": true])
            return ["ok": true, "session": mine, "source": file == nil ? "mic" : "file"]
        }
    }

    @available(macOS 26.0, *)
    static func feedFile(_ lt: LiveTranscriber, _ path: String) async {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let f48 = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            while file.framePosition < file.length, !Task.isCancelled {
                guard let b = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: 4096) else { break }
                try file.read(into: b, frameCount: 4096)
                if b.frameLength == 0 { break }
                lt.feed(b)
                try await Task.sleep(nanoseconds: UInt64(Double(b.frameLength) / 48000 * 1e9))
            }
            for _ in 0..<24 where !Task.isCancelled {   // ~2 s of a quiet room
                guard let b = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: 4096) else { break }
                b.frameLength = 4096; lt.feed(b)
                try await Task.sleep(nanoseconds: UInt64(4096.0 / 48000 * 1e9))
            }
        } catch { SpeechInput.log("talk: test file error \(error)") }
    }

    /// Stop listening and return the final words.
    func stop() -> [String: Any] { let t = Self.wait { await self.stopNow() }; return ["ok": true, "text": t] }
    private func stopNow() async -> String {
        let (l, f) = lock.withLock { () -> (AnyObject?, Task<Void, Never>?) in let r = (live, feeder); live = nil; feeder = nil; return r }
        f?.cancel()
        guard #available(macOS 26.0, *), let lt = l as? LiveTranscriber else { return "" }
        let t = await lt.stop()
        Talk.push(["text": t, "listening": false])
        return t
    }
}

/// Nov 13: tiny voice-activity check for Talk mode. Voice = louder than 0.01 RMS (about -40 dB) for 0.15 s;
/// then 1.2 s below 0.006 RMS = the person paused. Fires once per listening turn.
final class VAD: @unchecked Sendable {
    private let lock = NSLock(); private var voiced = 0.0, quiet = 0.0, heard = false, fired = false
    func step(rms: Float, secs: Double) -> Bool {
        lock.withLock {
            if fired { return false }
            if rms > 0.01 { voiced += secs; quiet = 0; if voiced >= 0.15 { heard = true } }
            else if rms < 0.006 { quiet += secs }
            if heard && quiet >= 1.2 { fired = true; return true }
            return false
        }
    }
}

