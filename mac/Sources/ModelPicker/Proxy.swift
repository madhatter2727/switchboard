import Foundation
import Network

/// Small OpenAI-style server on 127.0.0.1:7777 that routes to whichever engine holds the model.
final class Proxy: NSObject, URLSessionDataDelegate {
    let port: NWEndpoint.Port = 7777
    var listener: NWListener?
    var session: URLSession!
    var relays: [Int: (NWConnection, Bool)] = [:]   // task id -> (connection, headerSent)
    let lock = NSLock()
    var lastMagnitude = ""

    func log(_ s: String) { FileHandle.standardError.write(("\(Date()) \(s)\n").data(using: .utf8)!) }

    func start() {
        ensureDirs()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        do { listener = try NWListener(using: params) } catch { log("cannot listen: \(error)"); exit(1) }
        listener?.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener?.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { self?.log("listener failed \(e)"); exit(1) }
            if case .ready = st { self?.log("Model Picker proxy listening on 127.0.0.1:7777") } }
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
    func route(_ model: String?) -> (EngineDef, String)? {
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
                for e in ENGINE_DEFS { for m in modelIds(e) { data.append(["id": m, "object": "model", "owned_by": e.id]) } }
                self.respond(c, 200, (try? JSONSerialization.data(withJSONObject: ["object": "list", "data": data])) ?? Data()) }
            return
        }
        if path == "/v1/chat/completions" && method == "POST" {
            guard var j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { err(c, 400, "Body must be JSON."); return }
            DispatchQueue.global().async {
                guard let (e, m) = self.route(j["model"] as? String) else { self.err(c, 400, "No model picked in Model Picker and none named in the request, or that model was not found on any engine."); return }
                self.log("chat -> \(e.id) / \(m)")
                guard ensureEngineUp(e) else { self.err(c, 503, "Could not start \(e.name)."); return }
                if e.id == "magnitude" && self.lastMagnitude != m { _ = engineAct("load", "magnitude", ["model": m]); self.lastMagnitude = m }
                j["model"] = upstreamModel(e, m)
                if isRaptor(m) && j["reasoning_effort"] == nil { j["reasoning_effort"] = "none" }
                var r = URLRequest(url: URL(string: e.base + "/chat/completions")!); r.httpMethod = "POST"; r.timeoutInterval = 900
                r.httpBody = try? JSONSerialization.data(withJSONObject: j); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let t = self.session.dataTask(with: r)
                self.lock.lock(); self.relays[t.taskIdentifier] = (c, false); self.lock.unlock()
                c.stateUpdateHandler = { st in if case .cancelled = st { t.cancel() } else if case .failed = st { t.cancel() } }
                t.resume()
            }
            return
        }
        if path == "/" || path == "/health" { respond(c, 200, Data("{\"ok\":true,\"name\":\"Model Picker proxy\"}".utf8)); return }
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
        lock.lock(); let rel = relays.removeValue(forKey: t.taskIdentifier); lock.unlock()
        guard let c = rel?.0 else { return }
        if e != nil && (e as NSError?)?.code != NSURLErrorCancelled {
            let msg = "data: {\"error\":{\"message\":\"engine connection lost\"}}\n\n"
            c.send(content: Data(msg.utf8), completion: .contentProcessed { _ in })
        }
        c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}
