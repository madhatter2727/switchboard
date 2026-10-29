import Foundation

let home = NSHomeDirectory()
let OSAURUS = "/Applications/osaurus.app/Contents/Helpers/osaurus"
let MAGNITUDE = home + "/Applications/Magnitude.app/Contents/Resources/magnitude"
let LMS = home + "/.lmstudio/bin/lms"
let BONSAI = home + "/Models/bonsai2/start.sh"
let LFM3 = home + "/Models/lfm3/start.sh"   // LFM3 text (port 8110) and VL (port 8111) via its own llama.cpp copy; started only when picked
/// Apple Brain: serves Apple's built-in on-device model on 8100 (Tech Demos, Oct 22). Only started when "Apple (built-in)" is picked.
let APPLE_BRAIN = [home + "/Applications/Apple Brain.app/Contents/MacOS/AppleBrain", home + "/Projects/apple-brain/.build/release/AppleBrain"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
let APPLE_OWNER_TAG = "--owner"   // Switchboard's copy runs with "--owner switchboard", so stopping it never touches Apple Brain.app
func stopAppleBrain() { _ = runCmd("/usr/bin/pkill", ["-f", "AppleBrain --port 8100 --owner switchboard"]) }
let SUPPORT = home + "/Library/Application Support/Model Picker"
/// Saved chats. `--chats-dir PATH` points a test run at a copy instead of the real chats.
let CHATS: String = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--chats-dir"), a.count > i + 1 { return a[i + 1] }
    return SUPPORT + "/chats"
}()
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
    EngineDef(id: "lfm3text", name: "LFM3 1.7B", port: 8110, path: "/v1"),
    EngineDef(id: "lfm3vl", name: "LFM3-VL 2B", port: 8111, path: "/v1"),
    EngineDef(id: "apple", name: "Apple (built-in)", port: 8100, path: "/v1"),
    EngineDef(id: "ocr", name: "LightOnOCR-3 (document reader)", port: 8114, path: "/v1"),   // Oct 29: reads PDF pages; started only while reading, never listed as a chat model
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
let SINGLE_ALIAS = ["bonsai4b": "bonsai-2-4b", "bonsai9b": "bonsai-2-9b", "spark": "spark-x2.5-4b-mlx", "bonsai27b": "bonsai-2-27b", "apple": "apple-builtin", "lfm3text": "lfm3-1.7b", "lfm3vl": "lfm3-vl-2b"]
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
    _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8110"]); _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8111"]); _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8114"])
    if let (c, d) = syncHTTP("http://127.0.0.1:11434/api/ps", timeout: 2), c == 200,
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ms = j["models"] as? [[String: Any]] {
        for m in ms { if let n = m["name"] as? String { _ = syncHTTP("http://127.0.0.1:11434/api/generate", method: "POST", body: try? JSONSerialization.data(withJSONObject: ["model": n, "keep_alive": 0]), timeout: 10) } } }
    _ = runCmd(MAGNITUDE, ["models", "stop"])
}

func isEmbedName(_ m: String) -> Bool { m.lowercased().contains("embed") || m == "foundation" }

func offlineLines(_ id: String) -> [String] {
    switch id {
    // Never run `osaurus list` / `lms ls` here: those CLIs launch the Osaurus / LM Studio apps just to answer.
    // Use the last list seen while the engine was running, else what is on disk.
    case "osaurus": return cachedIds("osaurus") ?? osaurusDiskModels()
    case "lmstudio": return cachedIds("lmstudio") ?? lmstudioDiskModels()
    case "ollama": return cachedIds("ollama") ?? ollamaDiskModels()
    // Magnitude's own commands (`models status` etc.) need its server running and never start it, so while it is off
    // use the list saved the last time it was running (the same as Osaurus/Ollama). Reads one small file, starts nothing.
    case "magnitude": return cachedIds("magnitude") ?? []
    case "spark": return FileManager.default.fileExists(atPath: home + "/MLXModels/Spark-X2.5-4B-MLX-4bit") && FileManager.default.isExecutableFile(atPath: BUILTIN_SCRIPT["spark"]!) ? ["spark-x2.5-4b-mlx"] : []
    case "bonsai27b": return FileManager.default.fileExists(atPath: home + "/MLXModels/Bonsai-2-27B-JANG-CRACK-1.75bit") && FileManager.default.isExecutableFile(atPath: BUILTIN_SCRIPT["bonsai27b"]!) ? ["bonsai-2-27b"] : []
    case "bonsai4b": return FileManager.default.fileExists(atPath: home + "/Models/bonsai2/4b") ? ["bonsai-2-4b"] : []
    case "bonsai9b": return FileManager.default.fileExists(atPath: home + "/Models/bonsai2/9b") ? ["bonsai-2-9b"] : []
    case "apple": return APPLE_BRAIN.isEmpty ? [] : ["apple-builtin"]
    // LFM3: shown while off when its files and its own llama-server are on disk (reads only; starts nothing)
    case "lfm3text": return FileManager.default.fileExists(atPath: home + "/Models/lfm3/text/LFM3-1.7B-Q4_K_M.gguf") && FileManager.default.isExecutableFile(atPath: home + "/src/llama.cpp-lfm3/build/bin/llama-server") && FileManager.default.isExecutableFile(atPath: LFM3) ? ["lfm3-1.7b"] : []
    case "lfm3vl": return FileManager.default.fileExists(atPath: home + "/Models/lfm3/vl/LFM3-VL-2B-Q4_K_M.gguf") && FileManager.default.fileExists(atPath: home + "/Models/lfm3/vl/mmproj-LFM3-VL-2B-Q8_0.gguf") && FileManager.default.isExecutableFile(atPath: home + "/src/llama.cpp-lfm3/build/bin/llama-server") && FileManager.default.isExecutableFile(atPath: LFM3) ? ["lfm3-vl-2b"] : []
    default: return []
    }
}
/// Model ids of one engine (live list if running, else what is installed on disk).
func modelIds(_ e: EngineDef) -> [String] {
    if let (c, d) = syncHTTP(e.base + "/models", timeout: 2), c == 200,
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        var ids = ((j["data"] as? [[String: Any]]) ?? (j["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String ?? $0["name"] as? String }
        if let a = SINGLE_ALIAS[e.id] { ids = [a] }
        ids = ids.filter { !isEmbedName($0) }
        if ["osaurus", "lmstudio", "ollama", "magnitude"].contains(e.id) { saveCachedIds(e.id, ids) }
        return ids
    }
    let L = offlineLines(e.id).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    switch e.id {
    case "osaurus", "bonsai4b", "bonsai9b", "spark", "bonsai27b", "ollama", "apple", "lfm3text", "lfm3vl", "ocr": return L.filter { !isEmbedName($0) }
    case "lmstudio": return L.filter { !isEmbedName($0) }
    case "magnitude": return L   // saved ids of the models Magnitude can run (the live /models list leaves out the ones it can't)
    default: return []
    }
}

/// Start / stop / load engines. Shared by the window and the background proxy.
func engineAct(_ op: String, _ eng: String, _ d: [String: Any] = [:]) -> [String: Any] {
    switch (op, eng) {
    case ("start", _) where ["osaurus", "ollama", "lmstudio", "magnitude", "apple"].contains(eng):
        // One guarded launch: checks the port and the running app first, and coordinates the window and the proxy.
        if let e = ENGINE_DEFS.first(where: { $0.id == eng }) { return ["ok": ensureEngineUp(e)] }
    case ("stop", "osaurus"): _ = runCmd(OSAURUS, ["stop"]); Owned.forget(eng)
    case ("stop", "apple"): stopAppleBrain(); Owned.forget(eng)
    case ("stop", "lmstudio"): _ = runCmd(LMS, ["server", "stop"]); Owned.forget(eng)
    case ("stop", "magnitude"): _ = runCmd(MAGNITUDE, ["models", "stop"])
    case ("load", "magnitude"): _ = runCmd(MAGNITUDE, ["models", "load", d["model"] as? String ?? ""]); Owned.noteUsed("magnitude", d["model"] as? String ?? "")
    case ("start", "bonsai4b"): _ = runCmd("/bin/bash", [BONSAI, "4b"], detach: true); Owned.noteStarted(eng)
    case ("start", "bonsai9b"): _ = runCmd("/bin/bash", [BONSAI, "9b"], detach: true); Owned.noteStarted(eng)
    case ("start", "lfm3text"): _ = runCmd("/bin/bash", [LFM3, "text"], detach: true); Owned.noteStarted(eng)
    case ("start", "lfm3vl"): _ = runCmd("/bin/bash", [LFM3, "vl"], detach: true); Owned.noteStarted(eng)
    case ("stop", "lfm3text"): _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8110"]); Owned.forget(eng)
    case ("stop", "lfm3vl"): _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8111"]); Owned.forget(eng)
    case ("start", "ocr"): _ = runCmd("/bin/bash", [OCR_START], detach: true); Owned.noteStarted(eng)
    case ("stop", "ocr"): _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8114"]); Owned.forget(eng)
    case ("stop", "bonsai4b"): _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8097"]); Owned.forget(eng)
    case ("stop", "bonsai9b"): _ = runCmd("/usr/bin/pkill", ["-f", "llama-server.*--port 8098"]); Owned.forget(eng)
    case ("start", "spark"), ("start", "bonsai27b"):
        guard let sc = BUILTIN_SCRIPT[eng] else { break }
        if eng == "bonsai27b" { freeMemoryForBig() } else { stopBuiltin("bonsai27b") }
        _ = runCmd("/bin/launchctl", ["submit", "-l", jobLabel(eng), "--", sc]); Owned.noteStarted(eng)
    case ("stop", "spark"), ("stop", "bonsai27b"): stopBuiltin(eng); Owned.forget(eng)
    case ("list", _): return ["ids": modelIds(ENGINE_DEFS.first { $0.id == eng } ?? ENGINE_DEFS[0])]
    default: break
    }
    return ["ok": true]
}
/// Make sure an engine answers; start it if not. Returns false if it never came up.
func ensureEngineUp(_ e: EngineDef, seconds: Int = 300) -> Bool {
    if engineUp(e) { return true }
    if !GUARDED.contains(e.id) {
        _ = engineAct("start", e.id)
        for _ in 0..<seconds { Thread.sleep(forTimeInterval: 1); if engineUp(e) { return true } }
        return false
    }
    // Same-process guard (two callers in one app) + cross-process lock file (window and background proxy).
    let mx = engineMutex(e.id); mx.lock(); defer { mx.unlock() }
    let fd = open(SUPPORT + "/launch-\(e.id).lock", O_CREAT | O_RDWR, 0o644)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    if engineUp(e) { return true }   // someone else started it while we waited for the lock
    let wasRunning = appRunning(e.id)
    launchEngine(e.id, appAlreadyRunning: wasRunning)
    if !(e.id == "ollama" && wasRunning) { Owned.noteStarted(e.id, kind: wasRunning ? "server" : "app") }
    launchLog("\(e.id) start requested (app \(wasRunning ? "already running, server only" : "not running, launched")) by \(isProxyProcess ? "proxy" : "window")")
    for _ in 0..<seconds { Thread.sleep(forTimeInterval: 1); if engineUp(e) { return true } }
    launchLog("\(e.id) did not answer within \(seconds)s")
    return false
}
/// Backends that are separate apps/services and get the guarded, start-on-demand launch.
let GUARDED: Set<String> = ["osaurus", "ollama", "lmstudio", "magnitude", "apple"]
var isProxyProcess: Bool { CommandLine.arguments.contains("--proxy") }
private var _mutexes: [String: NSLock] = [:]; private let _mutexLock = NSLock()
func engineMutex(_ id: String) -> NSLock { _mutexLock.lock(); defer { _mutexLock.unlock() }
    if let m = _mutexes[id] { return m }; let m = NSLock(); _mutexes[id] = m; return m }
func pgrepAny(_ pats: [String]) -> Bool { pats.contains { runCmd("/usr/bin/pgrep", ["-f", $0]).0 == 0 } }
func appRunning(_ id: String) -> Bool {
    switch id {
    case "osaurus": return pgrepAny(["osaurus.app/Contents/MacOS/osaurus"])
    case "ollama": return pgrepAny(["ollama serve", "Ollama.app/Contents/MacOS/Ollama"])
    case "lmstudio": return pgrepAny(["LM Studio.app/Contents/MacOS/LM Studio"])
    case "magnitude": return pgrepAny(["magnitude serve", "Magnitude.app/Contents/MacOS"])
    case "apple": return pgrepAny(["AppleBrain --port 8100 --owner switchboard"])
    default: return false
    }
}
let BREW_OLLAMA = home + "/Library/LaunchAgents/sh.brew.ollama.plist"
/// Starts the backend once, in the background (no window, no focus change).
func launchEngine(_ id: String, appAlreadyRunning: Bool) {
    switch id {
    case "osaurus":
        // `osaurus serve` starts the server; if the app is closed it opens it hidden (menu bar only).
        // (`open -g -j` was tested: Osaurus still shows its main window and takes focus, so it is not used.)
        _ = runCmd(OSAURUS, ["serve", "--yes"], detach: true)
    case "ollama":
        if appAlreadyRunning { return }   // the server is up or starting; just wait for the port
        if FileManager.default.fileExists(atPath: BREW_OLLAMA) {   // Tara's Ollama runs as a Homebrew background service
            _ = runCmd("/bin/launchctl", ["kickstart", "gui/\(getuid())/sh.brew.ollama"])
        } else { _ = runCmd("/usr/bin/open", ["-g", "-j", "-a", "Ollama"]) }
    case "lmstudio": _ = runCmd(LMS, ["server", "start"])
    case "magnitude": if !appAlreadyRunning { _ = runCmd(MAGNITUDE, ["serve"], detach: true) }
    case "apple":   // tiny helper (no model download; Apple's model is part of macOS)
        if !appAlreadyRunning && !APPLE_BRAIN.isEmpty { _ = runCmd(APPLE_BRAIN, ["--port", "8100", "--owner", "switchboard"], detach: true) }
    default: break
    }
}
func launchLog(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let p = SUPPORT + "/engine-launches.log"
    if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: p, atomically: true, encoding: .utf8) }
}
// ---- model lists without waking anything ----
let MODEL_CACHE = SUPPORT + "/model-cache.json"
private let _cacheLock = NSLock()
func cachedIds(_ id: String) -> [String]? {
    guard let d = FileManager.default.contents(atPath: MODEL_CACHE),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String]], let v = j[id], !v.isEmpty else { return nil }
    return v
}
func saveCachedIds(_ id: String, _ ids: [String]) {
    _cacheLock.lock(); defer { _cacheLock.unlock() }
    var j = (FileManager.default.contents(atPath: MODEL_CACHE).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] }) ?? [:]
    if j[id] == ids { return }; j[id] = ids
    if let d = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]) { try? d.write(to: URL(fileURLWithPath: MODEL_CACHE), options: .atomic) }
}
/// Osaurus serves the MLX model folders in ~/MLXModels (and ~/MLXModels/<org>/); ids are the folder names, lowercased.
func osaurusDiskModels() -> [String] {
    let fm = FileManager.default; let root = home + "/MLXModels"; var out: [String] = []
    for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
        let pa = root + "/" + a
        if fm.fileExists(atPath: pa + "/config.json") { out.append(a.lowercased()); continue }
        for b in (try? fm.contentsOfDirectory(atPath: pa)) ?? [] where fm.fileExists(atPath: pa + "/" + b + "/config.json") { out.append(b.lowercased()) }
    }
    return out.sorted()
}
func ollamaDiskModels() -> [String] {
    let fm = FileManager.default; let root = home + "/.ollama/models/manifests/registry.ollama.ai/library"; var out: [String] = []
    for n in (try? fm.contentsOfDirectory(atPath: root)) ?? [] { for t in (try? fm.contentsOfDirectory(atPath: root + "/" + n)) ?? [] where !t.hasPrefix(".") { out.append(t == "latest" ? n + ":latest" : n + ":" + t) } }
    return out.sorted()
}
func lmstudioDiskModels() -> [String] {
    let fm = FileManager.default; var roots = [home + "/.lmstudio/models"]
    if let d = fm.contents(atPath: home + "/.lmstudio/settings.json"), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let f = j["downloadsFolder"] as? String, fm.fileExists(atPath: f) { roots.append(f) }
    var out: [String] = []
    for r in roots { for pub in (try? fm.contentsOfDirectory(atPath: r)) ?? [] where !pub.hasPrefix(".") {
        for m in (try? fm.contentsOfDirectory(atPath: r + "/" + pub)) ?? [] where !m.hasPrefix(".") { out.append((pub + "/" + m).lowercased()) } } }
    return out.filter { !isEmbedName($0) }.sorted()
}
func isRaptor(_ m: String) -> Bool { m.lowercased().contains("raptor") }
