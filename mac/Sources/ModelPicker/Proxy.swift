import Foundation
import Network

let PROXY_PID = SUPPORT + "/helper-7777.pid"

/// Small OpenAI-style server on 127.0.0.1:7777 that routes to whichever engine holds the model.
final class Proxy: NSObject, URLSessionDataDelegate {
    let port: NWEndpoint.Port = 7777
    var listener: NWListener?
    var session: URLSession!
    var relays: [Int: (NWConnection, Bool)] = [:]   // task id -> (connection, headerSent)
    var relayEngine: [Int: String] = [:]
    var relayTok: [Int: String] = [:]   // task id -> activity token (15-minute idle stop)
    func done(_ eng: String) { lock.lock(); inFlight[eng] = max(0, (inFlight[eng] ?? 1) - 1); if otherUse[eng] != nil { otherUse[eng] = Date() }; lock.unlock() }
    let lock = NSLock()
    var lastMagnitude = ""
    var inFlight: [String: Int] = [:]          // engine -> requests being answered right now
    var otherUse: [String: Date] = [:]         // engine -> last use by an app other than Switchboard / Ask My Mac
    /// Engines to keep even when both apps are closed: mid-answer, or used by some other local app in the last `s` seconds.
    func busyEngines(otherAppsWithin s: Double) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(inFlight.filter { $0.value > 0 }.keys).union(otherUse.filter { Date().timeIntervalSince($0.value) < s }.keys)
    }

    func log(_ s: String) { FileHandle.standardError.write(("\(Date()) \(s)\n").data(using: .utf8)!) }

    func start() {
        ensureDirs(); try? "\(getpid())".write(toFile: PROXY_PID, atomically: true, encoding: .utf8)
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        do { listener = try NWListener(using: params) } catch { log("cannot listen: \(error)"); exit(1) }
        listener?.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener?.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { self?.log("listener failed \(e)"); exit(1) }
            if case .ready = st { self?.log("Switchboard proxy listening on 127.0.0.1:7777") } }
        listener?.start(queue: .global())
    }

    func accept(_ c: NWConnection) {
        c.start(queue: .global()); var buf = Data()
        func more() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
                if let d = data { buf.append(d) }
                if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buf[buf.startIndex..<r.lowerBound], encoding: .utf8) ?? ""
                    var clen = 0
                    for l in head.split(separator: "\r\n") where l.lowercased().hasPrefix("content-length:") { clen = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
                    let body = Data(buf[r.upperBound...])
                    if body.count >= clen { self.handle(c, head, Data(body.prefix(clen))); return }
                }
                if done || err != nil { c.cancel(); return }
                more()
            }
        }
        more()
    }

    func respond(_ c: NWConnection, _ code: Int, _ body: Data, type: String = "application/json") {
        let st = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 502: "Bad Gateway", 503: "Service Unavailable"][code] ?? "OK"
        var h = "HTTP/1.1 \(code) \(st)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nConnection: close\r\n\r\n"
        var out = Data(h.utf8); out.append(body); h = ""
        c.send(content: out, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
    func err(_ c: NWConnection, _ code: Int, _ msg: String) {
        let j = try? JSONSerialization.data(withJSONObject: ["error": ["message": msg, "type": "model_picker_error"]])
        respond(c, code, j ?? Data())
    }

    func picked() -> (String, String)? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: STATE)), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let e = j["e"] as? String, let m = j["m"] as? String else { return nil }
        return (e, m)
    }
    func route(_ model: String?, body j: [String: Any] = [:]) -> (EngineDef, String)? {
        if model == "auto" {   // Oct 29: "auto" uses Auto's rules (see autoRouteForProxy), not the window's last pick
            let r = autoRouteForProxy(j, ids: { id in ENGINE_DEFS.first { $0.id == id }.map(modelIds) ?? [] })
            log("auto -> \(r.eng) / \(r.model) (\(r.why))")
            if let e = ENGINE_DEFS.first(where: { $0.id == r.eng }) { return (e, r.model) }
        }
        let p = picked()
        if model == nil || ["", "auto", "default", "picked"].contains(model!) {
            guard let p = p, let e = ENGINE_DEFS.first(where: { $0.id == p.0 }) else { return nil }
            return (e, p.1)
        }
        let m = model!
        if let p = p, p.1 == m, let e = ENGINE_DEFS.first(where: { $0.id == p.0 }) { return (e, m) }
        let running = ENGINE_DEFS.filter { engineUp($0) }
        for e in running + ENGINE_DEFS.filter({ x in !running.contains { $0.id == x.id } }) where modelIds(e).contains(m) { return (e, m) }
        return nil
    }

    func handle(_ c: NWConnection, _ head: String, _ body: Data) {
        let first = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = first.split(separator: " "); guard parts.count >= 2 else { c.cancel(); return }
        let method = String(parts[0]); let path = String(parts[1]).components(separatedBy: "?")[0]
        if method == "OPTIONS" { respond(c, 204, Data()); return }
        if path == "/v1/models" && method == "GET" {
            DispatchQueue.global().async {
                var data: [[String: Any]] = [["id": "auto", "object": "model", "owned_by": "model-picker"]]
                for e in ENGINE_DEFS where e.id != "ocr" && e.id != "notes" && e.id != "search" { for m in modelIds(e) { data.append(["id": m, "object": "model", "owned_by": e.id]) } }
                self.respond(c, 200, (try? JSONSerialization.data(withJSONObject: ["object": "list", "data": data])) ?? Data()) }
            return
        }
        if path == "/v1/chat/completions" && method == "POST" {
            guard var j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { err(c, 400, "Body must be JSON."); return }
            DispatchQueue.global().async {
                guard let (e, m) = self.route(j["model"] as? String, body: j) else { self.err(c, 400, "No model picked in Switchboard and none named in the request, or that model was not found on any engine."); return }
                let ua = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("user-agent:") }.map(String.init) ?? ""
                let known = ua.contains("AskMyMac") || ua.contains("Ask%20My%20Mac") || ua.contains("Switchboard")
                self.lock.lock(); self.inFlight[e.id, default: 0] += 1; if !known { self.otherUse[e.id] = Date() }; self.lock.unlock()
                self.log("chat -> \(e.id) / \(m)  [\(ua)]")
                Owned.noteUsed(e.id, m)
                guard ensureEngineUp(e) else { self.done(e.id); self.err(c, 503, "Could not start \(e.name)."); return }
                if e.id == "magnitude" && self.lastMagnitude != m { _ = engineAct("load", "magnitude", ["model": m]); self.lastMagnitude = m }
                j["model"] = upstreamModel(e, m)
                if isRaptor(m) && j["reasoning_effort"] == nil { j["reasoning_effort"] = "none" }
                let actTok = UUID().uuidString; Owned.noteActivity(engine: e.id, token: actTok, begin: true)
                var r = URLRequest(url: URL(string: e.base + "/chat/completions")!); r.httpMethod = "POST"; r.timeoutInterval = 900
                r.httpBody = try? JSONSerialization.data(withJSONObject: j); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let t = self.session.dataTask(with: r)
                self.lock.lock(); self.relays[t.taskIdentifier] = (c, false); self.relayEngine[t.taskIdentifier] = e.id; self.relayTok[t.taskIdentifier] = actTok; self.lock.unlock()
                c.stateUpdateHandler = { st in if case .cancelled = st { t.cancel() } else if case .failed = st { t.cancel() } }
                t.resume()
            }
            return
        }
        if path == "/switchboard/owned" && method == "POST" {
            // Ask My Mac reports an engine it launched (e.g. Osaurus), so it is stopped when neither app is open.
            if let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let id = j["engine"] as? String, ENGINE_DEFS.contains(where: { $0.id == id }) {
                Owned.noteStarted(id, kind: (j["kind"] as? String) == "server" ? "server" : "app", by: (j["by"] as? String).map { String($0.prefix(32)) } ?? "other app")
                respond(c, 200, Data("{\"ok\":true}".utf8))
            } else { err(c, 400, "Need {\"engine\": id}.") }
            return
        }
        if path == "/" || path == "/health" { respond(c, 200, Data("{\"ok\":true,\"name\":\"Switchboard proxy\"}".utf8)); return }
        err(c, 404, "Not found. Use /v1/models or /v1/chat/completions.")
    }

    // ---- relay upstream -> client ----
    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive resp: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let rel = relays[t.taskIdentifier]; lock.unlock()
        if let (c, _) = rel, let h = resp as? HTTPURLResponse {
            let type = h.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            let head = "HTTP/1.1 \(h.statusCode) OK\r\nContent-Type: \(type)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        }
        completionHandler(.allow)
    }
    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let rel = relays[t.taskIdentifier]; lock.unlock()
        rel?.0.send(content: data, completion: .contentProcessed { _ in })
    }
    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
        lock.lock(); let rel = relays.removeValue(forKey: t.taskIdentifier); let eng = relayEngine.removeValue(forKey: t.taskIdentifier); let tok = relayTok.removeValue(forKey: t.taskIdentifier); lock.unlock()
        if let eng = eng { done(eng); if let tok = tok { Owned.noteActivity(engine: eng, token: tok, begin: false) } }
        guard let c = rel?.0 else { return }
        if e != nil && (e as NSError?)?.code != NSURLErrorCancelled {
            let msg = "data: {\"error\":{\"message\":\"engine connection lost\"}}\n\n"
            c.send(content: Data(msg.utf8), completion: .contentProcessed { _ in })
        }
        c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// The 7777 helper's "auto" (Oct 29). Same keyword rules as the window's Auto (CODE_RX / FILE_RX copied from web/app.js),
/// applied to the last user message. Differences: Apple (built-in) is never picked here (other apps send long system
/// prompts and tools; Apple holds ~4,000 tokens), and a request that carries tools goes to an agent-capable model.
/// Order: picture -> LFM3-VL > Bonsai 4B > Bonsai 9B (with tools: Bonsai 4B > 9B first, LFM3-VL has no tools);
/// coding -> Bonsai 9B > Spark > Raptor; files/calendar words or tools -> Raptor (Osaurus); else Bonsai 4B > Raptor.
let PROXY_CODE_RX = try! NSRegularExpression(pattern: #"(?<!\b(?:area|zip|postal|promo|country|dress|morse|discount|coupon|access|qr|bar|pin) )\b(?:code|coding|script|bug|debug|html|css|javascript|js|python|swift|function|program|snake|regex|compile|error in|sql|api|refactor|algorithm|for loop|while loop|snippet|stack ?trace|unit test|typescript|bash)\b|\b(?:build|make|create|write|develop|code|program)\b[^.?!]{0,25}\b(?:app|game)\b|\b(?:html|web|browser|video|text|python|javascript)\s+(?:app|game)\b"#, options: [.caseInsensitive])
let PROXY_FILE_RX = try! NSRegularExpression(pattern: #"\b(?:pages|keynote|textedit|docx|txt|markdown|notes app|my notes|the notes|take (?:a )?notes?|add (?:a )?notes?|save (?:a )?notes?|file|files|folder|folders|directory|calendar|schedule|meeting|meetings|event|events|move|rename|search|downloads|desktop|documents|screenshot|screenshots|pdf|doc|docs|document|documents|open)\b"#, options: [.caseInsensitive])
func autoRouteForProxy(_ j: [String: Any], ids: (String) -> [String]) -> (eng: String, model: String, why: String) {
    let msgs = j["messages"] as? [[String: Any]] ?? []
    func text(_ c: Any?) -> String { if let t = c as? String { return t }; return ((c as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ") }
    func hasImg(_ c: Any?) -> Bool { ((c as? [[String: Any]]) ?? []).contains { ($0["type"] as? String) == "image_url" } }
    let users = msgs.filter { ($0["role"] as? String) == "user" }
    let last = text(users.last?["content"]); let rng = NSRange(last.startIndex..., in: last)
    let pic = users.contains { hasImg($0["content"]) }
    let tools = !((j["tools"] as? [Any]) ?? []).isEmpty
    func have(_ e: String) -> Bool { !ids(e).isEmpty }
    let raptor = ids("osaurus").first { $0.lowercased().contains("raptor") } ?? "raptor-0.6-4b-jang_6m"
    if pic {
        if tools { if have("bonsai4b") { return ("bonsai4b", "bonsai-2-4b", "picture + tools") }; if have("bonsai9b") { return ("bonsai9b", "bonsai-2-9b", "picture + tools") } }
        if have("lfm3vl") { return ("lfm3vl", "lfm3-vl-2b", "picture") }
        if have("bonsai4b") { return ("bonsai4b", "bonsai-2-4b", "picture") }
        if have("bonsai9b") { return ("bonsai9b", "bonsai-2-9b", "picture") }
    }
    if PROXY_CODE_RX.firstMatch(in: last, range: rng) != nil {
        if have("bonsai9b") { return ("bonsai9b", "bonsai-2-9b", "coding") }
        if have("spark") { return ("spark", "spark-x2.5-4b-mlx", "coding") }
        return ("osaurus", raptor, "coding (no coder installed)")
    }
    if PROXY_FILE_RX.firstMatch(in: last, range: rng) != nil { return ("osaurus", raptor, "files or calendar") }
    if tools { return ("osaurus", raptor, "the app sent tools") }
    if have("bonsai4b") { return ("bonsai4b", "bonsai-2-4b", "quick chat") }
    return ("osaurus", raptor, "quick chat")
}
