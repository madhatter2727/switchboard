import Foundation
import AVFoundation
import AppKit

/// Notes tab (Oct 29): Switchboard's OWN voice notes, separate from the Bark Voice Notes app (which is never touched).
/// Record -> Stop -> the speech becomes text with Underdog Bark 3.0 Clean (Switchboard's own copy of the engine on
/// 127.0.0.1:8115, started when needed, stopped after 15 idle minutes) -> a saved note (title, date, text, editable).
/// Saved in notes/<id>.json (+ the recording in notes/audio/) and as a readable copy in
/// ~/Documents/Switchboard Creations/Notes/. Delete = move to the Trash (the window always asks first).
/// Questions about notes go to LFM3 1.7B (see NoteAsk).
let NOTES_DIR = ProcessInfo.processInfo.environment["SB_NOTES_DIR"] ?? (SUPPORT + "/notes")   // env = tests only
let NOTES_AUDIO = NOTES_DIR + "/audio"
let NOTES_MD_DIR = ProcessInfo.processInfo.environment["SB_NOTES_MD_DIR"] ?? (home + "/Documents/Switchboard Creations/Notes")
let NOTES_PORT = 8115
let NOTES_START = home + "/Models/switchboard-notes/start.sh"

enum NoteStore {
    static let lock = NSLock()
    static func ok(_ id: String) -> Bool { !id.isEmpty && id.count < 80 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
    static func file(_ id: String) -> String { NOTES_DIR + "/" + id + ".json" }
    static func newId() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return "n-" + f.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }
    static func load(_ id: String) -> [String: Any]? {
        guard ok(id), let d = FileManager.default.contents(atPath: file(id)) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    static func all() -> [[String: Any]] {
        let fs = ((try? FileManager.default.contentsOfDirectory(atPath: NOTES_DIR)) ?? []).filter { $0.hasSuffix(".json") }
        return fs.compactMap { load(String($0.dropLast(5))) }.sorted { ($0["created"] as? Double ?? 0) > ($1["created"] as? Double ?? 0) }
    }
    static func autoTitle(_ text: String) -> String {
        let first = text.split(whereSeparator: { ".!?,;:\n".contains($0) }).first.map(String.init) ?? text
        let words = first.split(separator: " ").prefix(8).joined(separator: " ")
        let t = words.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return t.isEmpty ? "Voice note" : String(t.prefix(1)).uppercased() + String(t.dropFirst())
    }
    /// Readable copy name: date + time + the note's short code (unique, and stays the same when the title is edited).
    static func mdName(_ id: String) -> String {
        let p = id.split(separator: "-")   // n-yyyyMMdd-HHmmss-xxxx
        guard p.count == 4, p[1].count == 8, p[2].count == 6 else { return "Note \(id).md" }
        let d = p[1], t = p[2]
        return "Note \(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2)) \(t.prefix(4)) \(p[3]).md"
    }
    /// Create (no id) or update a note. Writes the JSON and the readable .md copy.
    static func save(_ d: [String: Any]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(atPath: NOTES_DIR, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        var id = d["id"] as? String ?? ""
        var n: [String: Any] = [:]
        if ok(id), let old = load(id) { n = old } else { id = newId(); n = ["id": id, "created": now] }
        let text = (d["text"] as? String ?? n["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var title = (d["title"] as? String ?? n["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = autoTitle(text) }
        n["text"] = text; n["title"] = String(title.prefix(120)); n["updated"] = now
        for k in ["audio", "audioSeconds", "sttSeconds", "engine"] where d[k] != nil { n[k] = d[k] }
        let created = n["created"] as? Double ?? now
        n["md"] = NOTES_MD_DIR + "/" + mdName(id)
        guard let j = try? JSONSerialization.data(withJSONObject: n, options: [.prettyPrinted, .sortedKeys]) else { return ["ok": false, "err": "Could not save the note."] }
        do { try j.write(to: URL(fileURLWithPath: file(id)), options: .atomic) } catch { return ["ok": false, "err": "Could not save the note."] }
        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .short
        let md = "# \(n["title"] as! String)\n\n_\(df.string(from: Date(timeIntervalSince1970: created)))_ · Switchboard note\n\n\(text)\n"
        try? FileManager.default.createDirectory(atPath: NOTES_MD_DIR, withIntermediateDirectories: true)
        try? md.write(toFile: n["md"] as! String, atomically: true, encoding: .utf8)
        n["ok"] = true; return n
    }
    /// Moves the note, its readable copy and its recording to the macOS Trash (never a permanent delete).
    static func trash(_ id: String) -> [String: Any] {
        guard let n = load(id) else { return ["ok": false, "err": "Note not found."] }
        let fm = FileManager.default; var moved = 0
        for p in [file(id), n["md"] as? String ?? "", n["audio"] as? String ?? ""] where !p.isEmpty && fm.fileExists(atPath: p) {
            if (try? fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)) != nil { moved += 1 } }
        return ["ok": !fm.fileExists(atPath: file(id)), "moved": moved]
    }
}

/// Recording: AAC .m4a, mono 16 kHz (what the speech model wants), kept next to the note.
final class NoteRecorder: NSObject {
    static let shared = NoteRecorder()
    var rec: AVAudioRecorder?; var path = ""; var t0 = Date()
    func start() -> [String: Any] {
        if rec?.isRecording == true { return ["ok": true, "already": true] }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return ["ok": false, "err": "Microphone access is off for Switchboard. Turn it on in System Settings > Privacy & Security > Microphone."]
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0); var allowed = false
            AVCaptureDevice.requestAccess(for: .audio) { allowed = $0; sem.signal() }; sem.wait()
            if !allowed { return ["ok": false, "err": "Switchboard needs the microphone to record a note."] }
        default: break }
        try? FileManager.default.createDirectory(atPath: NOTES_AUDIO, withIntermediateDirectories: true)
        path = NOTES_AUDIO + "/" + NoteStore.newId() + ".m4a"
        let s: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        var out: [String: Any] = ["ok": false, "err": "Could not start recording."]
        DispatchQueue.main.sync {
            guard let r = try? AVAudioRecorder(url: URL(fileURLWithPath: path), settings: s) else { return }
            r.isMeteringEnabled = true
            if r.record() { rec = r; t0 = Date(); out = ["ok": true, "path": path] }
        }
        return out
    }
    func level() -> [String: Any] {
        var o: [String: Any] = ["recording": false]
        DispatchQueue.main.sync { if let r = rec, r.isRecording { r.updateMeters(); o = ["recording": true, "secs": Date().timeIntervalSince(t0), "db": r.averagePower(forChannel: 0)] } }
        return o
    }
    func stop() -> [String: Any] {
        var o: [String: Any] = ["ok": false, "err": "Not recording."]
        DispatchQueue.main.sync { if let r = rec { let secs = Date().timeIntervalSince(t0); r.stop(); rec = nil; o = ["ok": true, "path": path, "secs": secs] } }
        return o
    }
}

enum NoteSTT {
    static var def: EngineDef { ENGINE_DEFS.first { $0.id == "notes" }! }
    /// Audio file -> text, on Switchboard's own Bark engine (8115). Starts it if needed.
    static func transcribe(_ path: String) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return ["ok": false, "err": "The recording is missing."] }
        guard ensureEngineUp(def, seconds: 90) else { _ = engineAct("stop", "notes"); return ["ok": false, "err": "The speech engine (Underdog Bark) did not start."] }
        let tok = UUID().uuidString
        Owned.noteActivity(engine: "notes", token: tok, begin: true); defer { Owned.noteActivity(engine: "notes", token: tok, begin: false) }
        let t0 = Date()
        guard let (c, d) = syncHTTP("http://127.0.0.1:\(NOTES_PORT)/transcribe", method: "POST", body: try? JSONSerialization.data(withJSONObject: ["path": path]), timeout: 900),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return ["ok": false, "err": "The speech engine did not answer."] }
        if c != 200 { return ["ok": false, "err": o["error"] as? String ?? "The speech engine had a problem."] }
        return ["ok": true, "text": o["text"] as? String ?? "", "sttSeconds": o["seconds"] ?? 0, "audioSeconds": o["audio_seconds"] ?? 0, "wall": Date().timeIntervalSince(t0)]
    }
    /// Transcribe + save as a new note (what happens after Stop, and the --note-from-audio test).
    static func noteFrom(_ path: String) -> [String: Any] {
        let r = transcribe(path); guard r["ok"] as? Bool == true else { return r }
        var n = NoteStore.save(["text": r["text"] ?? "", "audio": path, "audioSeconds": r["audioSeconds"] ?? 0, "sttSeconds": r["sttSeconds"] ?? 0, "engine": "Underdog Bark 3.0 Clean"])
        n["wall"] = r["wall"]; return n
    }
}

/// "Ask about my notes": all notes if they fit (about 60,000 characters), otherwise the best keyword matches.
enum NoteAsk {
    static var budget: Int { Int(ProcessInfo.processInfo.environment["SB_NOTES_BUDGET"] ?? "") ?? 60_000 }
    static func prompt(_ question: String) -> [String: Any] {
        let ns = NoteStore.all(); guard !ns.isEmpty else { return ["ok": false, "err": "You don't have any notes yet. Record one first."] }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let items = ns.map { n -> (String, String) in
            let t = n["title"] as? String ?? "Note"; let when = df.string(from: Date(timeIntervalSince1970: n["created"] as? Double ?? 0))
            return (t, "=== Note: \"\(t)\" (\(when)) ===\n" + (n["text"] as? String ?? "") + "\n\n") }
        let total = items.reduce(0) { $0 + $1.1.count }
        var chosen = items.indices.map { $0 }; var how = "all \(items.count) notes"
        if total > budget {
            let ts = DocAsk.terms(question); let lows = items.map { $0.1.lowercased() }
            let sc = items.indices.map { i in (i, ts.reduce(0) { $0 + DocAsk.count(lows[i], $1) }) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            var used = 0; chosen = []
            for (i, _) in sc { let c = items[i].1.count; if used + c > budget { continue }; chosen.append(i); used += c }
            how = "the \(chosen.count) best-matching of \(items.count) notes"
        }
        var sys = "You answer questions about the user's own voice notes. Use ONLY the notes below. Always say which note you used by its title in quotes, like (from \"Grocery list\"). If the notes don't say, answer plainly that they don't. Keep answers short and clear.\n\n"
        for i in chosen { sys += items[i].1 }
        return ["ok": true, "system": sys, "notes": chosen.map { items[$0].0 }, "how": how, "chars": sys.count]
    }
}
