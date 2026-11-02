import Foundation

/// Local models run only while Switchboard or Ask My Mac is open (Tara, Oct 21).
/// Every engine Switchboard starts (from the window or the 7777 helper) and every model it loads into a
/// shared engine (Ollama, LM Studio, Magnitude) is written to owned-engines.json. When neither app is
/// running, the 7777 helper stops exactly those, nothing else. Never touched: One Space's helpers
/// (8080/8081), Photo Reader (8093), Mind Map Live's Qwen (8082), the Ollama/LM Studio apps themselves.
let OWNED = SUPPORT + "/owned-engines.json"
let NEVER_TOUCH_PORTS: Set<Int> = [8080, 8081, 8082, 8093, 7777]

enum Owned {
    @discardableResult
    static func withLock<T>(_ f: (inout [String: Any]) -> T) -> T {
        ensureDirs()
        let fd = open(SUPPORT + "/owned.lock", O_CREAT | O_RDWR, 0o644); if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var j = (FileManager.default.contents(atPath: OWNED).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let r = f(&j)
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys, .prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: OWNED), options: .atomic) }
        return r
    }
    static var who: String { isProxyProcess ? "helper-7777" : "window" }
    /// kind: "server" (we started only the server of an app that was already open) or "app" (we launched it).
    static func noteStarted(_ id: String, kind: String = "app", by: String? = nil) {
        withLock { j in var s = j["started"] as? [String: Any] ?? [:]
            if s[id] == nil { s[id] = ["kind": kind, "by": by ?? who, "at": Date().timeIntervalSince1970] }; j["started"] = s }
        launchLog("owned: \(id) started by \(by ?? who) (\(kind))")
    }
    static func forget(_ id: String) { withLock { j in var s = j["started"] as? [String: Any] ?? [:]; s[id] = nil; j["started"] = s } }
    static func noteUsed(_ eng: String, _ model: String) {
        guard ["ollama", "lmstudio", "magnitude"].contains(eng), !model.isEmpty else { return }
        withLock { j in var u = j["used"] as? [String: [String]] ?? [:]; var l = u[eng] ?? []
            if !l.contains(model) { l.append(model) }; u[eng] = l; j["used"] = u }
    }
    /// Records which engine/model a request from the window goes to (by its local port).
    static func noteRequest(url: URL, body: Data?) {
        guard let port = url.port, let e = ENGINE_DEFS.first(where: { $0.port == port }), ["ollama", "lmstudio", "magnitude"].contains(e.id),
              let b = body, let j = try? JSONSerialization.jsonObject(with: b) as? [String: Any], let m = j["model"] as? String else { return }
        if (j["keep_alive"] as? Int) == 0 { return }   // that is an unload, not a use
        DispatchQueue.global().async { noteUsed(e.id, m) }
    }
    static var isEmpty: Bool {
        guard let d = FileManager.default.contents(atPath: OWNED), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return true }
        return ((j["started"] as? [String: Any]) ?? [:]).isEmpty && ((j["used"] as? [String: Any]) ?? [:]).isEmpty
    }

    /// Stops what Switchboard started / loaded, except engines listed in `keep`. Returns what it stopped.
    @discardableResult
    static func stopAll(reason: String, keep: Set<String> = []) -> [String] {
        var done: [String] = []
        withLock { j in
            var s = j["started"] as? [String: [String: Any]] ?? [:]
            var u = j["used"] as? [String: [String]] ?? [:]
            for (eng, models) in u where !keep.contains(eng) {
                switch eng {
                case "ollama":
                    for m in models { _ = syncHTTP("http://127.0.0.1:11434/api/generate", method: "POST", body: try? JSONSerialization.data(withJSONObject: ["model": m, "keep_alive": 0]), timeout: 10) }
                case "lmstudio": if appRunning("lmstudio") { for m in models { _ = runCmd(LMS, ["unload", m]) } }
                case "magnitude": _ = runCmd(MAGNITUDE, ["models", "stop"])
                default: break }
                done.append("\(eng) models \(models.joined(separator: ","))"); u[eng] = nil
            }
            for (id, info) in s where !keep.contains(id) {
                if let e = ENGINE_DEFS.first(where: { $0.id == id }), NEVER_TOUCH_PORTS.contains(e.port) { s[id] = nil; continue }
                let kind = info["kind"] as? String ?? "app"
                switch id {
                case "bonsai4b": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8097"])
                case "bonsai9b": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8098"])
                case "lfm3text": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8110"])
                case "lfm3vl": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8111"])
                case "ocr": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8114"])
                case "notes": _ = runCmd("/usr/bin/pkill", ["-f", "switchboard-notes/stt_server.py"])
                case "search": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8116"])
                case "little3d": stopLittle3d()   // Nov 2: pid file + alias marker; never the Scene Maker process
                case "spark", "bonsai27b": stopBuiltin(id)
                case "osaurus":
                    _ = runCmd(OSAURUS, ["stop"])
                    if kind == "app" { _ = runCmd("/usr/bin/pkill", ["-f", "osaurus.app/Contents/MacOS/osaurus"]) }   // we launched the app, so we close it
                case "lmstudio": _ = runCmd(LMS, ["server", "stop"])   // the LM Studio app itself is left as it was
                case "magnitude": _ = runCmd(MAGNITUDE, ["models", "stop"]); if kind == "app" { _ = runCmd("/usr/bin/pkill", ["-f", "magnitude serve"]) }
                case "apple": stopAppleBrain()   // only Switchboard's own copy; Apple Brain.app is left alone
                case "ollama": break   // Ollama's own background service stays (tiny); its models were unloaded above
                default: break }
                done.append(id); s[id] = nil
            }
            j["started"] = s; j["used"] = u
        }
        if !done.isEmpty { launchLog("owned: stopped [\(done.joined(separator: "; "))] because \(reason)") }
        return done
    }
}

/// Idle auto-stop (Tara, Oct 29): Switchboard's OWN small model servers stop after 15 minutes with no chat requests,
/// and start again on the next pick or message (the window and the 7777 helper both start an engine that is off).
/// Only these. Never Osaurus, Ollama, LM Studio, Magnitude, Bark (8099), One Space (8080/8081), Photo Reader (8093).
/// Only engines Switchboard itself started (listed under "started" in owned-engines.json) are ever stopped.
let IDLE_STOP_ENGINES: Set<String> = ["bonsai4b", "bonsai9b", "lfm3text", "lfm3vl", "little3d", "spark", "bonsai27b", "apple", "ocr", "notes", "search"]
let IDLE_STOP_SECONDS: Double = 15 * 60
/// Nov 2: the 3D Coder (8117, about 3.2 GB) stops after 10 min. For a test, a number of seconds (30 or more) in
/// Model Picker/little3d-idle-seconds overrides it; that file normally holds 600.
let LITTLE3D_IDLE_FILE = SUPPORT + "/little3d-idle-seconds"
func idleSeconds(_ id: String) -> Double {
    guard id == "little3d" else { return IDLE_STOP_SECONDS }
    if let t = try? String(contentsOfFile: LITTLE3D_IDLE_FILE, encoding: .utf8), let v = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 30 { return v }
    return 10 * 60
}
/// Nov 2: stop Switchboard's own 3D Coder copy. Uses the pid file the start script writes, and only kills that pid if its
/// command line carries the --alias switchboard-little3d marker (so a Scene Maker server on 8117 is never stopped).
let LITTLE3D_PID = SUPPORT + "/little3d.pid"
func stopLittle3d() {
    if let t = try? String(contentsOfFile: LITTLE3D_PID, encoding: .utf8), let pid = Int32(t.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
        let cmd = runCmd("/bin/ps", ["-o", "command=", "-p", "\(pid)"]).1
        if cmd.contains("--alias switchboard-little3d") { kill(pid, SIGTERM); launchLog("little3d: stopped pid \(pid) (ours)") }
    }
    _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--alias switchboard-little3d"])   // marker only, in case the pid file is stale
}
extension Owned {
    static let activityQ = DispatchQueue(label: "owned.activity")   // keeps begin/end of one request in order
    /// A chat request to one of Switchboard's own engines begins or ends: remember the time (and that it is mid-answer).
    static func noteActivity(url: URL, token: String, begin: Bool) {
        guard let port = url.port, url.path.hasSuffix("/chat/completions"),
              let e = ENGINE_DEFS.first(where: { $0.port == port }) else { return }
        noteActivity(engine: e.id, token: token, begin: begin)
    }
    static func noteActivity(engine id: String, token: String, begin: Bool) {
        guard IDLE_STOP_ENGINES.contains(id) else { return }
        activityQ.async {
            withLock { j in
                let now = Date().timeIntervalSince1970
                var lu = j["lastUse"] as? [String: Double] ?? [:]; lu[id] = now; j["lastUse"] = lu
                var busy = j["busy"] as? [String: Double] ?? [:]; busy[id + "|" + token] = begin ? now : nil; j["busy"] = busy
            }
        }
    }
    /// Stops Switchboard-started engines that have had no request for 15 minutes (the 7777 helper calls this every 30 s).
    /// dryRun: only reports. atOffset: pretend it is this many seconds later (for checks). Returns what it stopped (or would).
    @discardableResult
    static func stopIdle(dryRun: Bool = false, atOffset: Double = 0) -> [String] {
        var done: [String] = []
        let now = Date().timeIntervalSince1970 + atOffset
        withLock { j in
            var s = j["started"] as? [String: [String: Any]] ?? [:]
            let lu = j["lastUse"] as? [String: Double] ?? [:]
            var busy = j["busy"] as? [String: Double] ?? [:]
            if !dryRun { busy = busy.filter { now - $0.value < 45 * 60 }; j["busy"] = busy }   // older than 45 min = left over from a crash
            for (id, info) in s where IDLE_STOP_ENGINES.contains(id) {
                if let e = ENGINE_DEFS.first(where: { $0.id == id }), NEVER_TOUCH_PORTS.contains(e.port) { continue }
                if busy.contains(where: { $0.key.hasPrefix(id + "|") && now - $0.value < 45 * 60 }) { continue }   // mid-answer
                let last = max(lu[id] ?? 0, (info["at"] as? Double) ?? 0)
                guard now - last >= idleSeconds(id) else { continue }
                done.append(id)
                if dryRun { continue }
                switch id {
                case "bonsai4b": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8097"])
                case "bonsai9b": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8098"])
                case "lfm3text": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8110"])
                case "lfm3vl": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8111"])
                case "ocr": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8114"])
                case "notes": _ = runCmd("/usr/bin/pkill", ["-f", "switchboard-notes/stt_server.py"])
                case "search": _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8116"])
                case "little3d": stopLittle3d()   // Nov 2: pid file + alias marker; never the Scene Maker process
                case "spark", "bonsai27b": stopBuiltin(id)
                case "apple": stopAppleBrain()   // only Switchboard's own copy
                default: continue }
                s[id] = nil
            }
            if !dryRun { j["started"] = s }
        }
        if !dryRun && !done.isEmpty { launchLog("owned: stopped [\(done.joined(separator: ", "))] after their idle time with no requests (3D Coder 10 min, others 15 min)") }
        return done
    }
}

extension Owned {
    /// Ids of the engines Switchboard started (read-only look at owned-engines.json).
    static func startedIds() -> Set<String> {
        guard let d = FileManager.default.contents(atPath: OWNED), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return Set(((j["started"] as? [String: Any]) ?? [:]).keys)
    }
}
