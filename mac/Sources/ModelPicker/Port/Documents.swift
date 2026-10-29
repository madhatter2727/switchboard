import Foundation
import PDFKit
import AppKit

/// Read a document (Oct 29): a PDF's pages are turned into pictures and read one by one by LightOnOCR-3
/// (Switchboard's own engine "ocr" on 127.0.0.1:8114, started only while reading, stopped right after).
/// Every page's text is saved as soon as it is read (documents/<id>/p0001.txt ...), so Stop or a crash loses nothing
/// and a later read skips pages already done. When reading ends: pages.md (all pages) + a copy she can open in
/// ~/Documents/Switchboard Creations/Documents/. Questions about it go to LFM3 1.7B (see DocAsk).
let DOCS_DIR = SUPPORT + "/documents"
let OCR_PORT = 8114
let OCR_START = home + "/Models/lightonocr/start.sh"

enum DocStore {
    static let lock = NSLock()
    static var cache: [String: PDFDocument] = [:]
    static func pdf(_ path: String) -> PDFDocument? {
        lock.lock(); defer { lock.unlock() }
        if let d = cache[path] { return d }
        guard let d = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        if cache.count > 4 { cache.removeAll() }
        cache[path] = d; return d
    }
    /// Stable folder name: readable name + short fingerprint of path, size and date (same file -> same folder).
    static func id(for path: String) -> String {
        let a = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let key = path + "|\((a[.size] as? Int) ?? 0)|\(((a[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970)"
        var h: UInt64 = 1469598103934665603; for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let slug = String(base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (slug.isEmpty ? "document" : slug) + "-" + String(String(h, radix: 16).prefix(8))
    }
    static func dir(_ id: String) -> String { DOCS_DIR + "/" + id }
    static func pageFile(_ id: String, _ p: Int) -> String { dir(id) + String(format: "/p%04d.txt", p) }
    static func donePages(_ id: String) -> [Int] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir(id))) ?? []).compactMap { f in
            f.hasPrefix("p") && f.hasSuffix(".txt") ? Int(f.dropFirst().dropLast(4)) : nil }.sorted()
    }
    static func info(_ path: String) -> [String: Any] {
        guard let d = pdf(path) else { return ["ok": false, "err": "That PDF could not be opened."] }
        let id = id(for: path)
        try? FileManager.default.createDirectory(atPath: dir(id), withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        let meta: [String: Any] = ["name": name, "path": path, "pages": d.pageCount]
        if let j = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) { try? j.write(to: URL(fileURLWithPath: dir(id) + "/meta.json")) }
        return ["ok": true, "id": id, "name": name, "pages": d.pageCount, "done": donePages(id), "dir": dir(id)]
    }
    /// One page as a PNG data URL, longest side `maxSide` px (2048 = what the head-to-head test used), white background.
    static func render(_ path: String, page: Int, maxSide: CGFloat = 2048) -> String? {
        guard let d = pdf(path), page >= 1, page <= d.pageCount, let pg = d.page(at: page - 1) else { return nil }
        let b = pg.bounds(for: .mediaBox); let rot = abs(pg.rotation) % 180 == 90
        let w0 = rot ? b.height : b.width, h0 = rot ? b.width : b.height
        let s = maxSide / max(w0, h0); let w = Int((w0 * s).rounded()), h = Int((h0 * s).rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        lock.lock(); let tr = pg.transform(for: .mediaBox); lock.unlock()
        ctx.scaleBy(x: s, y: s); ctx.concatenate(tr)
        lock.lock(); pg.draw(with: .mediaBox, to: ctx); lock.unlock()
        guard let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
    static func savePage(_ id: String, _ p: Int, _ text: String) {
        try? FileManager.default.createDirectory(atPath: dir(id), withIntermediateDirectories: true)
        try? text.write(toFile: pageFile(id, p), atomically: true, encoding: .utf8)
    }
    static func pages(_ id: String) -> [(Int, String)] {
        donePages(id).map { ($0, (try? String(contentsOfFile: pageFile(id, $0), encoding: .utf8)) ?? "") }
    }
    static func meta(_ id: String) -> [String: Any] {
        (FileManager.default.contents(atPath: dir(id) + "/meta.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }
    /// Writes pages.md (all pages read so far) and a copy she can open. Returns both paths.
    static func finish(_ id: String) -> [String: Any] {
        let m = meta(id); let name = m["name"] as? String ?? id; let total = m["pages"] as? Int ?? 0
        let ps = pages(id)
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var md = "# \(name)\n\nRead on this Mac with LightOnOCR-3 on \(df.string(from: Date())). \(ps.count) of \(total) pages read.\n"
        for (p, t) in ps { md += "\n---\n\n## Page \(p)\n\n" + t.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
        let inner = dir(id) + "/pages.md"; try? md.write(toFile: inner, atomically: true, encoding: .utf8)
        let outDir = home + "/Documents/Switchboard Creations/Documents"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let outer = outDir + "/" + ((name as NSString).deletingPathExtension) + " (text).md"
        try? md.write(toFile: outer, atomically: true, encoding: .utf8)
        return ["ok": true, "pagesMd": inner, "openMd": outer, "read": ps.count, "pages": total]
    }
}

/// The reading job. One at a time. The window polls `status()`; the `--doc-read` test runs `run()` directly.
final class DocJob {
    let id: String, name: String, path: String, first: Int, last: Int, total: Int
    var current = 0, read = 0, skipped = 0, failed = 0, secs: [Double] = []
    var state = "starting", note = "", stop = false
    var preview = ""; var result: [String: Any] = [:]
    init(id: String, name: String, path: String, first: Int, last: Int, total: Int) { self.id = id; self.name = name; self.path = path; self.first = first; self.last = last; self.total = total }
}
enum DocReader {
    static let lock = NSLock()
    static var job: DocJob?
    static var ocrDef: EngineDef { ENGINE_DEFS.first { $0.id == "ocr" }! }
    static func start(_ path: String, first: Int = 1, last: Int = 0) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let j = job, ["starting", "reading"].contains(j.state) { return ["ok": false, "err": "Already reading \(j.name)."] }
        let inf = DocStore.info(path); guard inf["ok"] as? Bool == true, let id = inf["id"] as? String, let n = inf["pages"] as? Int else { return inf }
        let j = DocJob(id: id, name: inf["name"] as? String ?? "", path: path, first: max(1, first), last: last <= 0 ? n : min(n, last), total: n)
        job = j; Thread.detachNewThread { run(j) }
        return ["ok": true, "id": id, "pages": n]
    }
    static func stop() { lock.lock(); job?.stop = true; lock.unlock() }
    static func statusOf(_ j: DocJob) -> [String: Any] { lock.lock(); let o = job; job = j; lock.unlock(); let s = status(); lock.lock(); job = o; lock.unlock(); return s }
    static func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let j = job else { return ["state": "none"] }
        let avg = j.secs.isEmpty ? 0 : j.secs.reduce(0, +) / Double(j.secs.count)
        return ["state": j.state, "id": j.id, "name": j.name, "current": j.current, "first": j.first, "last": j.last, "total": j.total,
                "read": j.read, "skipped": j.skipped, "failed": j.failed, "avgSecs": avg, "note": j.note, "preview": j.preview, "result": j.result]
    }
    static func set(_ j: DocJob, _ f: (DocJob) -> Void) { lock.lock(); f(j); lock.unlock() }
    /// Reads pages first...last. Memory on a 16 GB Air: LFM3 is stopped first (if Switchboard started it), OCR is stopped after.
    static func run(_ j: DocJob, log: ((String) -> Void)? = nil) {
        let started = Owned.startedIds()
        for e in ["lfm3text", "lfm3vl"] where started.contains(e) { _ = engineAct("stop", e) }
        set(j) { $0.state = "starting"; $0.note = "Starting the document reader…" }
        guard ensureEngineUp(ocrDef, seconds: 180) else {
            set(j) { $0.state = "error"; $0.note = "The document reader (LightOnOCR) did not start." }; _ = engineAct("stop", "ocr"); return }
        set(j) { $0.state = "reading" }
        let done = Set(DocStore.donePages(j.id))
        for p in j.first...j.last {
            if j.stop { break }
            set(j) { $0.current = p }
            if done.contains(p) { set(j) { $0.skipped += 1 }; continue }
            let t0 = Date(); let tok = UUID().uuidString
            Owned.noteActivity(engine: "ocr", token: tok, begin: true)
            var text: String? = nil
            if let img = DocStore.render(j.path, page: p) {
                let body: [String: Any] = ["messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": img]]]]],
                                           "temperature": 0.2, "top_p": 0.9, "max_tokens": 6000, "stream": false]
                if let (c, d) = syncHTTP("http://127.0.0.1:\(OCR_PORT)/v1/chat/completions", method: "POST", body: try? JSONSerialization.data(withJSONObject: body), timeout: 300), c == 200,
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let msg = ((o["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String { text = msg }
            }
            Owned.noteActivity(engine: "ocr", token: tok, begin: false)
            let dt = Date().timeIntervalSince(t0)
            if let t = text {
                DocStore.savePage(j.id, p, t)
                set(j) { $0.read += 1; $0.secs.append(dt); if $0.preview.count < 1500 { $0.preview += ($0.preview.isEmpty ? "" : "\n\n") + "[Page \(p)]\n" + String(t.prefix(1500 - $0.preview.count)) } }
            } else { set(j) { $0.failed += 1 } }
            log?("{\"page\":\(p),\"secs\":\(String(format: "%.1f", dt)),\"ok\":\(text != nil),\"chars\":\(text?.count ?? 0)}")
        }
        _ = engineAct("stop", "ocr")   // free its memory right away (LFM3 is loaded only when she asks a question)
        let r = DocStore.finish(j.id)
        set(j) { $0.result = r; $0.state = $0.stop ? "stopped" : ($0.failed > 0 && $0.read == 0 ? "error" : "done"); $0.note = "" }
    }
}

/// Questions about a read document: picks the pages to send to LFM3 1.7B.
/// Everything is sent when it fits (about 90,000 characters, roughly 30,000 tokens, so answers stay quick);
/// otherwise the pages that best match the question's words go first (rare words count more), then in page order.
enum DocAsk {
    static var budget: Int { Int(ProcessInfo.processInfo.environment["SB_DOC_BUDGET"] ?? "") ?? 90_000 }   // test override only
    static let stop: Set<String> = ["the","and","for","are","was","what","which","who","whom","how","why","when","where","does","did","this","that","these","those","with","from","into","about","there","their","they","them","have","has","had","been","were","will","would","could","should","can","not","but","any","all","its","our","your","you","tell","give","show","list","please","document","page","pages","say","says"]
    static func terms(_ q: String) -> [String] {
        Array(Set(q.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) }))
    }
    static func count(_ hay: String, _ needle: String) -> Int { hay.components(separatedBy: needle).count - 1 }
    static func prompt(_ id: String, question: String) -> [String: Any] {
        let ps = DocStore.pages(id); let name = DocStore.meta(id)["name"] as? String ?? id
        guard !ps.isEmpty else { return ["ok": false, "err": "No pages of this document have been read yet."] }
        let total = ps.reduce(0) { $0 + $1.1.count + 20 }
        var chosen: [(Int, String)]
        var how = "all pages"
        if total <= budget { chosen = ps } else {
            let lows = ps.map { $0.1.lowercased() }; let ts = terms(question); let n = Double(ps.count)
            let idf = Dictionary(uniqueKeysWithValues: ts.map { t in (t, log(n / Double(max(1, lows.filter { $0.contains(t) }.count))) + 0.1) })
            let scored = ps.indices.map { i -> (Int, Double) in
                (i, ts.reduce(0.0) { s, t in let c = count(lows[i], t); return s + (c > 0 ? (1 + log(Double(c))) * (idf[t] ?? 0) : 0) }) }
            let order = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            var used = 0; var pick: [Int] = []
            for (i, sc) in order { if sc <= 0 && !pick.isEmpty { break }; let c = ps[i].1.count + 20; if used + c > budget { if pick.isEmpty { continue }; break }; pick.append(i); used += c }
            if pick.isEmpty { for i in ps.indices { let c = ps[i].1.count + 20; if used + c > budget { break }; pick.append(i); used += c } }
            chosen = pick.sorted().map { ps[$0] }; how = "the \(chosen.count) best-matching of \(ps.count) pages"
        }
        var sys = "You answer questions about the document \"\(name)\". Use ONLY the page text below. After each fact, give its page in brackets, like (p. 12). If the answer is not in these pages, say so plainly. Keep answers short and clear.\n\n"
        for (p, t) in chosen { sys += "=== Page \(p) ===\n" + t.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" }
        return ["ok": true, "system": sys, "pages": chosen.map { $0.0 }, "how": how, "read": ps.count, "name": name, "chars": sys.count]
    }
}
