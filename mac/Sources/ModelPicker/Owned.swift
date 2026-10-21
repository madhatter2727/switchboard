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
                case "spark", "bonsai27b": stopBuiltin(id)
                case "osaurus":
                    _ = runCmd(OSAURUS, ["stop"])
                    if kind == "app" { _ = runCmd("/usr/bin/pkill", ["-f", "osaurus.app/Contents/MacOS/osaurus"]) }   // we launched the app, so we close it
                case "lmstudio": _ = runCmd(LMS, ["server", "stop"])   // the LM Studio app itself is left as it was
                case "magnitude": _ = runCmd(MAGNITUDE, ["models", "stop"]); if kind == "app" { _ = runCmd("/usr/bin/pkill", ["-f", "magnitude serve"]) }
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
