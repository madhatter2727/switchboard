import Foundation

let home = NSHomeDirectory()
let OSAURUS = "/Applications/osaurus.app/Contents/Helpers/osaurus"
let MAGNITUDE = home + "/Applications/Magnitude.app/Contents/Resources/magnitude"
let LMS = home + "/.lmstudio/bin/lms"
let BONSAI = home + "/Models/bonsai2/start.sh"
let SUPPORT = home + "/Library/Application Support/Model Picker"
let CHATS = SUPPORT + "/chats"
let STATE = SUPPORT + "/state.json"

func ensureDirs() { try? FileManager.default.createDirectory(atPath: CHATS, withIntermediateDirectories: true) }

func localOK(_ us: String) -> URL? {
    guard let url = URL(string: us), let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
    return url
}
func runCmd(_ path: String, _ args: [String], detach: Bool = false, wait: Bool = true) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    var env = ProcessInfo.processInfo.environment; env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; p.environment = env
    let pipe = Pipe()
    if detach { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice } else { p.standardOutput = pipe; p.standardError = pipe }
    do { try p.run() } catch { return (-1, "\(error)") }
    if detach || !wait { return (0, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

struct EngineDef { let id: String; let name: String; let port: Int; let path: String
    var base: String { "http://127.0.0.1:\(port)\(path)" } }
let ENGINE_DEFS = [
    EngineDef(id: "osaurus", name: "Osaurus", port: 1337, path: "/v1"),
    EngineDef(id: "ollama", name: "Ollama", port: 11434, path: "/v1"),
    EngineDef(id: "lmstudio", name: "LM Studio", port: 1234, path: "/v1"),
    EngineDef(id: "magnitude", name: "Magnitude", port: 10100, path: "/inference/v1"),
    EngineDef(id: "bonsai4b", name: "Bonsai 2 4B", port: 8097, path: "/v1"),
    EngineDef(id: "bonsai9b", name: "Bonsai 2 9B", port: 8098, path: "/v1"),
    EngineDef(id: "spark", name: "Spark X2.5 4B", port: 8095, path: "/v1"),
    EngineDef(id: "bonsai27b", name: "Bonsai 2 27B", port: 8096, path: "/v1"),
]

/// Blocking GET/POST helper (used off the main thread).
func syncHTTP(_ url: String, method: String = "GET", body: Data? = nil, timeout: Double = 3) -> (Int, Data)? {
    guard let u = URL(string: url) else { return nil }
    var r = URLRequest(url: u); r.httpMethod = method; r.timeoutInterval = timeout; r.httpBody = body
    if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let sem = DispatchSemaphore(value: 0); var out: (Int, Data)? = nil
    let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = timeout
    URLSession(configuration: cfg).dataTask(with: r) { d, resp, e in
        if e == nil { out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data()) }; sem.signal() }.resume()
    sem.wait(); return out
}
func engineUp(_ e: EngineDef) -> Bool { if let (c, _) = syncHTTP(e.base + "/models", timeout: 2), c == 200 { return true }; return false }

/// Engines that serve exactly one model; the picker shows a friendly alias for it.
let SINGLE_ALIAS = ["bonsai4b": "bonsai-2-4b", "bonsai9b": "bonsai-2-9b", "spark": "spark-x2.5-4b-mlx", "bonsai27b": "bonsai-2-27b"]
/// What the engine itself calls the model in requests.
func upstreamModel(_ e: EngineDef, _ alias: String) -> String {
    if e.id == "spark" { return home + "/MLXModels/Spark-X2.5-4B-MLX-4bit" }
    if e.id == "bonsai27b" { return "bonsai-2-27b" }
    return alias
}
let BUILTIN_SCRIPT = ["spark": home + "/.askmymac/run-spark.sh", "bonsai27b": home + "/.askmymac/run-bonsai.sh"]
func jobLabel(_ id: String) -> String { "com.tara.modelpicker." + id }
func stopBuiltin(_ id: String) { _ = runCmd("/bin/launchctl", ["remove", jobLabel(id)]) }
/// Bonsai 27B is big (about 9 GB in memory on a 16 GB Mac): stop what the picker can safely stop first.
func freeMemoryForBig() {
    stopBuiltin("spark"); _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8097"]); _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8098"])
    if let (c, d) = syncHTTP("http://127.0.0.1:11434/api/ps", timeout: 2), c == 200,
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ms = j["models"] as? [[String: Any]] {
        for m in ms { if let n = m["name"] as? String { _ = syncHTTP("http://127.0.0.1:11434/api/generate", method: "POST", body: try? JSONSerialization.data(withJSONObject: ["model": n, "keep_alive": 0]), timeout: 10) } } }
    _ = runCmd(MAGNITUDE, ["models", "stop"])
}

func isEmbedName(_ m: String) -> Bool { m.lowercased().contains("embed") || m == "foundation" }

func offlineLines(_ id: String) -> [String] {
    switch id {
    case "osaurus": return runCmd(OSAURUS, ["list"]).1.split(separator: "\n").map(String.init)
    case "lmstudio": return runCmd(LMS, ["ls"]).1.split(separator: "\n").map(String.init)
    case "magnitude": return runCmd(MAGNITUDE, ["models", "status"]).1.split(separator: "\n").map(String.init)
    case "spark": return FileManager.default.fileExists(atPath: home + "/MLXModels/Spark-X2.5-4B-MLX-4bit") && FileManager.default.isExecutableFile(atPath: BUILTIN_SCRIPT["spark"]!) ? ["spark-x2.5-4b-mlx"] : []
    case "bonsai27b": return FileManager.default.fileExists(atPath: home + "/MLXModels/Bonsai-2-27B-JANG-CRACK-1.75bit") && FileManager.default.isExecutableFile(atPath: BUILTIN_SCRIPT["bonsai27b"]!) ? ["bonsai-2-27b"] : []
    case "bonsai4b": return FileManager.default.fileExists(atPath: home + "/Models/bonsai2/4b") ? ["bonsai-2-4b"] : []
    case "bonsai9b": return FileManager.default.fileExists(atPath: home + "/Models/bonsai2/9b") ? ["bonsai-2-9b"] : []
    default: return []
    }
}
/// Model ids of one engine (live list if running, else what is installed on disk).
func modelIds(_ e: EngineDef) -> [String] {
    if let (c, d) = syncHTTP(e.base + "/models", timeout: 2), c == 200,
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        var ids = ((j["data"] as? [[String: Any]]) ?? (j["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String ?? $0["name"] as? String }
        if let a = SINGLE_ALIAS[e.id] { ids = [a] }
        return ids.filter { !isEmbedName($0) }
    }
    let L = offlineLines(e.id).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    switch e.id {
    case "osaurus", "bonsai4b", "bonsai9b", "spark", "bonsai27b": return L.filter { !isEmbedName($0) }
    case "lmstudio":
        var out: [String] = []; var sec = ""
        for l in L { if l.hasPrefix("LLM") { sec = "llm" } else if l.hasPrefix("EMBEDDING") { sec = "emb" }
            else if sec == "llm" && !l.hasPrefix("You have"), let f = l.split(separator: " ").first { out.append(String(f)) } }
        return out
    case "magnitude":
        var out: [String] = []; var on = false
        for l in L { if l.hasPrefix("MODEL") && l.contains("MODEL ID") { on = true; continue }
            if on, let last = l.split(separator: " ").last { out.append(String(last)) } }
        return out
    default: return []
    }
}

/// Start / stop / load engines. Shared by the window and the background proxy.
func engineAct(_ op: String, _ eng: String, _ d: [String: Any] = [:]) -> [String: Any] {
    switch (op, eng) {
    case ("start", "osaurus"): _ = runCmd(OSAURUS, ["serve", "--yes"], detach: true)
    case ("stop", "osaurus"): _ = runCmd(OSAURUS, ["stop"])
    case ("start", "ollama"): _ = runCmd("/usr/bin/open", ["-a", "Ollama"])
    case ("start", "lmstudio"): _ = runCmd(LMS, ["server", "start"])
    case ("stop", "lmstudio"): _ = runCmd(LMS, ["server", "stop"])
    case ("start", "magnitude"): _ = runCmd(MAGNITUDE, ["serve"], detach: true)
    case ("stop", "magnitude"): _ = runCmd(MAGNITUDE, ["models", "stop"])
    case ("load", "magnitude"): _ = runCmd(MAGNITUDE, ["models", "load", d["model"] as? String ?? ""])
    case ("start", "bonsai4b"): _ = runCmd("/bin/bash", [BONSAI, "4b"], detach: true)
    case ("start", "bonsai9b"): _ = runCmd("/bin/bash", [BONSAI, "9b"], detach: true)
    case ("stop", "bonsai4b"): _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8097"])
    case ("stop", "bonsai9b"): _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8098"])
    case ("start", "spark"), ("start", "bonsai27b"):
        guard let sc = BUILTIN_SCRIPT[eng] else { break }
        if eng == "bonsai27b" { freeMemoryForBig() } else { stopBuiltin("bonsai27b") }
        _ = runCmd("/bin/launchctl", ["submit", "-l", jobLabel(eng), "--", sc])
    case ("stop", "spark"), ("stop", "bonsai27b"): stopBuiltin(eng)
    case ("list", _): return ["ids": modelIds(ENGINE_DEFS.first { $0.id == eng } ?? ENGINE_DEFS[0])]
    default: break
    }
    return ["ok": true]
}
/// Make sure an engine answers; start it if not. Returns false if it never came up.
func ensureEngineUp(_ e: EngineDef, seconds: Int = 300) -> Bool {
    if engineUp(e) { return true }
    _ = engineAct("start", e.id)
    for _ in 0..<seconds { Thread.sleep(forTimeInterval: 1); if engineUp(e) { return true } }
    return false
}
func isRaptor(_ m: String) -> Bool { m.lowercased().contains("raptor") }
