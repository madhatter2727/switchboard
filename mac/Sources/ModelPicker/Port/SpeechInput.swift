import AVFoundation
import Speech
import SwiftUI

/// Hold the mic to dictate into the text field. Recognition stays on this Mac.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var listening = false
    /// Full text for the field (what was already typed, plus the new phrase).
    @Published private(set) var dictation = ""
    @Published private(set) var hint = "Hold to talk. Speech stays on this Mac."
    @Published private(set) var warning: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var holding = false
    private var starting = false
    private var generation = 0
    private var utterance = 0
    private var prefix = ""

    nonisolated static func log(_ m: String) {
        let line = "\(Date()) \(m)\n"; let path = NSHomeDirectory() + "/Library/Logs/ModelPickerSpeech.log"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }
    private var buffers = 0
    init() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else {
            available = false
            fail("On-device dictation isn't available on this Mac.")
            return
        }
        available = true
    }

    func holdDown(currentDraft: String) {
        holding = true
        guard available, !listening, !starting else { return }
        prefix = currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        dictation = ""
        starting = true
        generation += 1
        utterance += 1
        let token = generation
        Task { await startIfHeld(token) }
    }

    func holdUp() {
        Self.log("holdUp: buffers=\(buffers) listening=\(listening) starting=\(starting)")
        let active = holding || starting || engine.isRunning || tapInstalled
        holding = false
        generation += 1
        starting = false
        listening = false
        // End the stream without cancelling so the last words can still arrive.
        guard active else { return }
        endCapture()
    }

    private func startIfHeld(_ token: Int) async {
        defer {
            if generation == token { starting = false }
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else {
            available = false
            fail("On-device dictation isn't available on this Mac.")
            return
        }
        guard await Self.allowSpeech() else {
            fail("Speech recognition is off. Turn it on in System Settings > Privacy & Security > Speech Recognition, then try again.")
            return
        }
        guard generation == token, holding else { return }
        guard await Self.allowMic() else {
            fail("Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone, then try again.")
            return
        }
        guard generation == token, holding else { return }
        do {
            try arm(recognizer)
        } catch {
            stopEngine()
            fail("The microphone didn't start.")
            return
        }
        guard generation == token, holding else {
            stopEngine()
            return
        }
        listening = true
        ready()
    }

    private func arm(_ recognizer: SFSpeechRecognizer) throws {
        stopEngine()
        let token = utterance
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechFailure.noInput
        }
        Self.log("arm: format \(format) onDevice=\(recognizer.supportsOnDeviceRecognition) locale=\(recognizer.locale.identifier) available=\(recognizer.isAvailable)")
        buffers = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            Task { @MainActor in self?.buffers += 1 }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let failed = error != nil
            if let e = error as NSError? { SpeechInput.log("recognizer error \(e.domain) \(e.code) \(e.localizedDescription)") }
            if result?.isFinal == true { SpeechInput.log("final: '\(text)'") }
            let finished = failed || result?.isFinal == true
            Task { @MainActor in
                guard let self, self.utterance == token else { return }
                self.apply(text, failed: failed, finished: finished)
            }
        }
    }

    private func apply(_ text: String, failed: Bool, finished: Bool) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty {
            let combined = prefix.isEmpty ? spoken : prefix + " " + spoken
            if combined != dictation { dictation = combined }
        }
        if finished {
            // The recognizer is done. Drop the tap so it cannot append to a finished request.
            if engine.isRunning { engine.stop() }
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            task = nil
            request = nil
        }
        guard failed, holding else { return }
        if spoken.isEmpty {
            fail("Didn't catch that. Hold the mic and try again.")
        }
        holdUp()
    }

    /// Stop the mic. Leaves the recognizer to deliver the final phrase.
    private func endCapture() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
    }

    private func stopEngine() {
        endCapture()
        task?.cancel()
        task = nil
        request = nil
        engine.reset()
    }

    private func ready() {
        hint = "Hold to talk. Speech stays on this Mac."
        warning = nil
    }

    private func fail(_ message: String) {
        Self.log("fail: \(message)")
        hint = message
        warning = message
    }

    private static func allowSpeech() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status != .notDetermined { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus == .authorized)
            }
        }
    }

    private static func allowMic() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status != .notDetermined { return false }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private enum SpeechFailure: Error {
        case noInput
    }
}

