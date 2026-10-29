import Foundation
import AppKit
import SQLite3
import Accelerate
import PDFKit

/// "Search my files" (Oct 29). She adds folders (files stay where they are; nothing is copied or moved). Switchboard keeps its
/// OWN index in search/index.sqlite: text, PDF, Word, RTF/ODT, web and code files are read and cut into parts; photos are indexed
/// by file name (like One Space). Meaning search uses EmbeddingGemma 2 (Switchboard's own engine "search" on 127.0.0.1:8116,
/// 15-minute idle stop). Exact words are boosted (SQLite FTS5), so files containing her words always show up.
/// One Space is never touched: its folder list is only READ from bookmarks.json (never its index database).
let SEARCH_DIR = ProcessInfo.processInfo.environment["SB_SEARCH_DIR"] ?? (SUPPORT + "/search")   // env = tests only
let SEARCH_PORT = 8116
let SEARCH_START = home + "/Models/switchboard-search/start.sh"
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SearchIndex {
    static let lock = NSRecursiveLock()
    static var db: OpaquePointer?
    static var vecCache: [(path: String, chunk: Int64, v: [Float])]? = nil
    static let textExt: Set<String> = ["txt","md","markdown","csv","tsv","json","html","htm","xml","yaml","yml","rtf","rtfd","doc","docx","odt","pdf","log","tex",
        "swift","py","js","ts","tsx","jsx","java","c","h","cpp","hpp","m","mm","go","rs","rb","php","sh","zsh","css","scss","sql","kt","r","lua","pl","ini","toml","cfg"]
    static let photoExt: Set<String> = ["jpg","jpeg","png","heic","webp","gif","tif","tiff"]
    static let skipDirs: Set<String> = ["node_modules", ".git", "__MACOSX", "Library", ".build", "build", "DerivedData", "venv", ".venv", "__pycache__", "Pods"]

    // ---- database ----
    @discardableResult static func open() -> OpaquePointer? {
        lock.lock(); defer { lock.unlock() }
        if let d = db { return d }
        try? FileManager.default.createDirectory(atPath: SEARCH_DIR, withIntermediateDirectories: true)
        var d: OpaquePointer?
        guard sqlite3_open_v2(SEARCH_DIR + "/index.sqlite", &d, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return nil }
        db = d
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS folders(path TEXT PRIMARY KEY, added REAL, last_indexed REAL, files INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, folder TEXT, name TEXT, kind TEXT, mtime REAL, size INTEGER, chunks INTEGER, embedded INTEGER);
        CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, path TEXT, ord INTEGER, text TEXT, emb BLOB);
        CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(text, name, path UNINDEXED, chunk UNINDEXED, tokenize='unicode61 remove_diacritics 2');
        """)
        return d
    }
    static func exec(_ sql: String) { lock.lock(); defer { lock.unlock() }; sqlite3_exec(db, sql, nil, nil, nil) }
    /// Runs a statement with bound values; returns rows as arrays of Any (Int64, Double, String, Data or NSNull).
    @discardableResult static func q(_ sql: String, _ args: [Any?] = []) -> [[Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let d = open() else { return [] }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(d, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let k = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(st, k, v, -1, SQLITE_TRANSIENT)
            case let v as Int: sqlite3_bind_int64(st, k, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, k, v)
            case let v as Double: sqlite3_bind_double(st, k, v)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(st, k, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(st, k)
            }
        }
        var rows: [[Any]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [Any] = []
            for c in 0..<sqlite3_column_count(st) {
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: r.append(sqlite3_column_int64(st, c))
                case SQLITE_FLOAT: r.append(sqlite3_column_double(st, c))
                case SQLITE_TEXT: r.append(String(cString: sqlite3_column_text(st, c)))
                case SQLITE_BLOB: let n = Int(sqlite3_column_bytes(st, c)); r.append(n > 0 ? Data(bytes: sqlite3_column_blob(st, c), count: n) : Data())
                default: r.append(NSNull())
                }
            }
            rows.append(r)
        }
        return rows
    }

    // ---- folders ----
    static func folders() -> [[String: Any]] {
        q("SELECT path, added, last_indexed, (SELECT COUNT(*) FROM files WHERE folder=folders.path) FROM folders ORDER BY added").map {
            ["path": $0[0], "name": (($0[0] as? String ?? "") as NSString).lastPathComponent, "lastIndexed": $0[2] is NSNull ? 0 : $0[2], "files": $0[3],
             "exists": FileManager.default.fileExists(atPath: $0[0] as? String ?? "")] }
    }
    static func addFolder(_ raw: String) -> [String: Any] {
        let p = (raw as NSString).standardizingPath
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return ["ok": false, "err": "That folder doesn't exist."] }
        guard p.hasPrefix(home + "/") || p.hasPrefix("/Volumes/") else { return ["ok": false, "err": "Pick a folder inside your home folder."] }
        if p.hasPrefix(home + "/Library") || p.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return ["ok": false, "err": "Hidden and Library folders can't be searched."] }
        for f in folders() { let fp = f["path"] as? String ?? ""; if p == fp || p.hasPrefix(fp + "/") { return ["ok": true, "path": fp, "already": true] } }
        q("INSERT OR IGNORE INTO folders(path, added) VALUES(?, ?)", [p, Date().timeIntervalSince1970])
        return ["ok": true, "path": p]
    }
    /// Takes a folder out of Switchboard's search index only. Her files are not touched.
    static func removeFolder(_ p: String) -> [String: Any] {
        q("DELETE FROM fts WHERE path IN (SELECT path FROM files WHERE folder=?)", [p])
        q("DELETE FROM chunks WHERE path IN (SELECT path FROM files WHERE folder=?)", [p])
        q("DELETE FROM files WHERE folder=?", [p]); q("DELETE FROM folders WHERE path=?", [p])
        lock.lock(); vecCache = nil; lock.unlock()
        return ["ok": true]
    }
    @MainActor static func pickFolder() -> String? {
        let pan = NSOpenPanel(); pan.canChooseDirectories = true; pan.canChooseFiles = false; pan.allowsMultipleSelection = false
        pan.message = "Pick a folder to search. Files stay where they are; nothing is copied or moved."; pan.prompt = "Add folder"
        NSApp.activate(ignoringOtherApps: true)
        return pan.runModal() == .OK ? pan.url?.path : nil
    }
    /// One Space's folders, READ ONLY from its bookmarks.json (never its index). Nothing is added until she clicks Add.
    static func oneSpaceFolders() -> [[String: Any]] {
        let f = home + "/Library/Application Support/OneSpace/bookmarks.json"
        guard let d = FileManager.default.contents(atPath: f), let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        let mine = Set(folders().compactMap { $0["path"] as? String })
        return arr.compactMap { b in
            guard let s = b["bookmarkData"] as? String, let bd = Data(base64Encoded: s) else { return nil }
            var stale = false
            let u = (try? URL(resolvingBookmarkData: bd, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: bd, options: [.withoutUI, .withoutMounting, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
            guard let p = u?.path else { return nil }
            return ["name": (b["name"] as? String ?? (p as NSString).lastPathComponent).trimmingCharacters(in: .whitespaces), "path": p, "added": mine.contains(p)]
        }
    }

    // ---- reading files ----
    static func kind(_ path: String) -> String? {
        let e = (path as NSString).pathExtension.lowercased()
        return textExt.contains(e) ? "text" : photoExt.contains(e) ? "photo" : nil
    }
    static func words(_ name: String) -> String {
        ((name as NSString).deletingPathExtension).replacingOccurrences(of: "[_\\-.]+", with: " ", options: .regularExpression)
    }
    static func readText(_ path: String) -> String {
        let e = (path as NSString).pathExtension.lowercased()
        let url = URL(fileURLWithPath: path); var t = ""
        func attr(_ ty: NSAttributedString.DocumentType) -> String { (try? NSAttributedString(url: url, options: [.documentType: ty], documentAttributes: nil).string) ?? "" }
        switch e {
        case "pdf": t = PDFDocument(url: url)?.string ?? ""
        case "rtf": t = attr(.rtf)
        case "rtfd": t = attr(.rtfd)
        case "docx": t = attr(.officeOpenXML)
        case "doc": t = attr(.docFormat)
        case "odt": t = attr(.openDocument)
        default:
            guard let d = FileManager.default.contents(atPath: path), !d.isEmpty else { return "" }
            if let u = String(data: d, encoding: .utf8) { t = u } else if !d.prefix(4096).contains(0), let l = String(data: d, encoding: .isoLatin1) { t = l } else { return "" }
        }
        if e == "html" || e == "htm" || e == "xml" {   // tags out, words in
            return t.replacingOccurrences(of: "<script[\\s\\S]*?</script>|<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        return t
    }
    static let chunkSize = 1000, overlap = 150, maxChunks = 2000
    static func chunks(_ text: String) -> [String] {
        let t = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        let a = Array(t); var out: [String] = []; var i = 0
        while i < a.count && out.count < maxChunks {
            var j = min(a.count, i + chunkSize)
            if j < a.count, let sp = a[(i + chunkSize * 2 / 3)..<j].lastIndex(where: { $0 == " " || $0 == "\n" }) { j = sp }
            let c = String(a[i..<j]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.isEmpty { out.append(c) }
            if j >= a.count { break }
            i = max(i + 1, j - overlap)
        }
        return out
    }

    // ---- embeddings ----
    static var engine: EngineDef { ENGINE_DEFS.first { $0.id == "search" }! }
    static func embed(_ texts: [String]) -> [[Float]]? {
        let tok = UUID().uuidString
        Owned.noteActivity(engine: "search", token: tok, begin: true); defer { Owned.noteActivity(engine: "search", token: tok, begin: false) }
        let body: [String: Any] = ["model": "embeddinggemma2", "input": texts.map { String($0.prefix(1800)) }]
        guard let (c, d) = syncHTTP("http://127.0.0.1:\(SEARCH_PORT)/v1/embeddings", method: "POST", body: try? JSONSerialization.data(withJSONObject: body), timeout: 120), c == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let data = o["data"] as? [[String: Any]], data.count == texts.count else { return nil }
        return data.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.map { e in
            var v = ((e["embedding"] as? [Any]) ?? []).map { Float(($0 as? NSNumber)?.doubleValue ?? 0) }
            var n: Float = 0; vDSP_svesq(v, 1, &n, vDSP_Length(v.count)); n = sqrt(n)
            if n > 0 { var s = 1 / n; vDSP_vsmul(v, 1, &s, &v, 1, vDSP_Length(v.count)) }
            return v }
    }
    static func blob(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func floats(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    static func vectors() -> [(path: String, chunk: Int64, v: [Float])] {
        lock.lock(); defer { lock.unlock() }
        if let c = vecCache { return c }
        let c = q("SELECT path, id, emb FROM chunks WHERE emb IS NOT NULL").compactMap { r -> (String, Int64, [Float])? in
            guard let p = r[0] as? String, let id = r[1] as? Int64, let d = r[2] as? Data, d.count >= 4 else { return nil }; return (p, id, floats(d)) }
        vecCache = c.map { (path: $0.0, chunk: $0.1, v: $0.2) }; return vecCache!
    }

    // ---- search ----
    static let stop: Set<String> = ["the","and","for","are","was","what","which","who","how","why","when","where","does","did","this","that","with","from","about","have","has","had","been","were","will","would","could","should","can","not","but","any","all","its","our","your","you","find","show","file","files","my","me","a","an","of","in","on","to","is","it","or","i","do","up","get","got","many","much","make","makes","made","going","go","some","like","just","want","there","here","is","be","am","so","than","then","into","out","over","also","very","really","thing","things","stuff","something","anything","look","looking","search","folder","folders","document","documents"]
    static func terms(_ q: String) -> [String] {
        var seen = Set<String>(); return q.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count >= 2 && !stop.contains($0) && seen.insert($0).inserted }
    }
    static func search(_ query: String, limit: Int = 20) -> [String: Any] {
        let t0 = Date(); let ts = terms(query)
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return ["ok": false, "err": "Type what you're looking for."] }
        // 1) exact words (FTS5): which files contain each word (text or file name)
        var hits: [String: Set<String>] = [:]; var chunkHits: [Int64: Int] = [:]
        for t in ts {
            let w = t.replacingOccurrences(of: "\"", with: "")
            let m = w.count >= 6 ? "\"\(w)\"*" : "\"\(w)\" OR \"\(w)s\""   // short words: whole word (or plural) only, so "bread" doesn't match "breadth"
            for r in q("SELECT path, chunk FROM fts WHERE fts MATCH ? LIMIT 5000", [m]) {
                if let p = r[0] as? String { hits[p, default: []].insert(t) }
                if let c = r[1] as? Int64 { chunkHits[c, default: 0] += 1 }
            }
        }
        // 2) meaning: cosine between the question and every part
        var sem: [String: (Float, Int64)] = [:]; var meaning = true; var note = ""
        let vs = vectors()
        if !vs.isEmpty {
            if ensureEngineUp(engine, seconds: 60), let qv = embed(["task: search result | query: " + query])?.first {
                for e in vs where e.v.count == qv.count {
                    var dot: Float = 0; vDSP_dotpr(qv, 1, e.v, 1, &dot, vDSP_Length(qv.count))
                    let boosted = dot + 0.03 * Float(chunkHits[e.chunk] ?? 0)
                    if boosted > (sem[e.path]?.0 ?? -9) { sem[e.path] = (boosted, e.chunk) }
                }
            } else { meaning = false; note = "Meaning search is waiting for its engine, so these are exact-word matches only." }
        } else if q("SELECT COUNT(*) FROM files").first?.first as? Int64 ?? 0 == 0 { return ["ok": true, "results": [], "note": "Add a folder first, then search."] }
        // 3) combine: meaning + exact-word boost (+ file-name boost). Files with her words always make the list.
        var cands = Set(sem.keys).union(hits.keys)
        if cands.count > 4000 { cands = Set(sem.sorted { $0.value.0 > $1.value.0 }.prefix(3000).map { $0.key }).union(hits.keys) }
        let info = Dictionary(uniqueKeysWithValues: q("SELECT path, folder, name, kind, mtime FROM files").compactMap { r -> (String, [Any])? in (r[0] as? String).map { ($0, r) } })
        // rare words count more (a word found in every file barely helps)
        let nFiles = Double(max(1, info.count))
        var df: [String: Int] = [:]; for (_, set) in hits { for t in set { df[t, default: 0] += 1 } }
        let idf = Dictionary(uniqueKeysWithValues: ts.map { ($0, log(1 + nFiles / Double(max(1, df[$0] ?? 0)))) })
        let idfAll = ts.reduce(0.0) { $0 + (idf[$1] ?? 0) }
        let wantsPhoto = ts.contains { ["photo","photos","picture","pictures","pic","pics","image","images","selfie","screenshot"].contains($0) }
        let bestSem = Double(sem.values.map { $0.0 }.max() ?? 0)
        var scored: [(String, Double, Double, Double, Int64?)] = []
        for p in cands {
            guard let r = info[p] else { continue }
            let name = (r[2] as? String ?? "").lowercased()
            let s = Double(sem[p]?.0 ?? 0)
            let kw = idfAll > 0 ? (hits[p] ?? []).reduce(0.0) { $0 + (idf[$1] ?? 0) } / idfAll : 0
            let nameHit = ts.contains { name.contains($0) } ? 1.0 : 0.0
            let photoHit = wantsPhoto && (r[3] as? String) == "photo" ? 1.0 : 0.0
            let total = s + 0.35 * kw + 0.15 * nameHit + 0.08 * photoHit
            scored.append((p, total, s, kw, sem[p]?.1))
        }
        scored.sort { $0.1 > $1.1 }
        // keep only reasonable meaning matches unless they contain her words
        // meaning-only matches must be close to the best one (EmbeddingGemma rates most text as somewhat similar)
        let top = scored.filter { $0.3 > 0.15 || $0.2 >= bestSem - 0.12 || !meaning }.prefix(limit)
        let results: [[String: Any]] = top.map { (p, total, s, kw, ch) in
            let r = info[p]!; var snip = ""
            var best = ch
            if kw > 0 { // prefer the part with the most of her words for the snippet
                let rows = q("SELECT id, text FROM chunks WHERE path=?", [p])
                var bestN = -1
                for row in rows { let low = (row[1] as? String ?? "").lowercased(); let n = ts.reduce(0) { $0 + (low.contains($1) ? 1 : 0) }; if n > bestN { bestN = n; best = row[0] as? Int64 } }
            }
            if let b = best, let t = q("SELECT text FROM chunks WHERE id=?", [b]).first?.first as? String { snip = snippet(t, ts) }
            let strength = s >= bestSem - 0.04 ? "close" : s >= bestSem - 0.1 ? "related" : "loose"
            return ["path": p, "name": r[2], "folder": ((p as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath, "kind": r[3],
                    "snippet": snip, "words": kw > 0 ? Array(hits[p] ?? []).sorted() : [], "meaning": meaning ? strength : "", "score": (total * 1000).rounded() / 1000, "chunk": best ?? 0]
        }
        return ["ok": true, "results": results, "meaning": meaning, "note": note, "secs": Date().timeIntervalSince(t0), "terms": ts]
    }
    static func snippet(_ t: String, _ ts: [String]) -> String {
        let flat = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let low = flat.lowercased()
        if let r = ts.compactMap({ low.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let start = low.distance(from: low.startIndex, to: r.lowerBound)
            let a = max(0, start - 90); let s = Array(flat)
            return (a > 0 ? "…" : "") + String(s[a..<min(s.count, a + 260)]) + (a + 260 < s.count ? "…" : "")
        }
        return String(flat.prefix(260)) + (flat.count > 260 ? "…" : "")
    }

    // ---- ask about results ----
    static func askPrompt(_ query: String, question: String, paths: [String]) -> [String: Any] {
        let ts = terms(question + " " + query); let sysText = "You are a helpful assistant. Answer in plain sentences, using only the excerpts from the user's files that they give you. Say which file each fact came from, in quotes, like (from \"budget.txt\"). If the excerpts don't answer the question, say so plainly. Never call tools. Keep it short."
        var sys = "Excerpts from my files:\n\n"
        var used: [String] = []; var budget = 24_000
        for p in paths.prefix(6) {
            let rows = q("SELECT text FROM chunks WHERE path=? ORDER BY ord", [p]).compactMap { $0.first as? String }
            guard !rows.isEmpty else { continue }
            let ranked = rows.enumerated().map { (i, t) in (i, t, ts.reduce(0) { $0 + DocAsk.count(t.lowercased(), $1) }) }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            let take = ranked.prefix(3).sorted { $0.0 < $1.0 }.map { $0.1 }.joined(separator: "\n…\n")
            let block = "--- From the file \"\((p as NSString).lastPathComponent)\" ---\n" + String(take.prefix(6000)) + "\n\n"
            if block.count > budget { break }; budget -= block.count; sys += block; used.append((p as NSString).lastPathComponent)
        }
        guard !used.isEmpty else { return ["ok": false, "err": "Search first, then ask about the results."] }
        return ["ok": true, "system": sysText, "context": sys, "files": used, "chars": sys.count]
    }
}

/// The indexing job (one at a time). Walks the folders, reads new or changed files, embeds their parts, and forgets files that are gone
/// (from the index only). The window polls status(); `--search-index` runs it directly.
final class SearchJob { var state = "starting", note = "", current = "", folder = ""; var scanned = 0, toDo = 0, done = 0, unchanged = 0, removed = 0, failed = 0, chunks = 0; var stop = false; var secs = 0.0; var meaning = true }
enum SearchIndexer {
    static let lock = NSLock(); static var job: SearchJob?
    static var lastRun: Date = .distantPast
    static func start(only: String? = nil) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let j = job, ["starting", "indexing"].contains(j.state) { return ["ok": true, "running": true] }
        let j = SearchJob(); job = j; Thread.detachNewThread { run(j, only: only) }; return ["ok": true]
    }
    static func stop() { lock.lock(); job?.stop = true; lock.unlock() }
    static func set(_ j: SearchJob, _ f: (SearchJob) -> Void) { lock.lock(); f(j); lock.unlock() }
    static func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let j = job else { return ["state": "none"] }
        return ["state": j.state, "note": j.note, "current": j.current, "folder": j.folder, "scanned": j.scanned, "toDo": j.toDo, "done": j.done, "unchanged": j.unchanged,
                "removed": j.removed, "failed": j.failed, "chunks": j.chunks, "secs": j.secs, "meaning": j.meaning]
    }
    static func run(_ j: SearchJob, only: String? = nil, log: ((String) -> Void)? = nil) {
        let t0 = Date(); let fm = FileManager.default; SearchIndex.open()
        let fs = SearchIndex.folders().compactMap { $0["path"] as? String }.filter { only == nil || $0 == only }
        set(j) { $0.state = "indexing"; $0.note = "Looking for new or changed files…" }
        var work: [(String, String, Double, Int)] = []   // path, folder, mtime, size
        var seen = Set<String>()
        for f in fs {
            set(j) { $0.folder = (f as NSString).lastPathComponent }
            guard let en = fm.enumerator(at: URL(fileURLWithPath: f), includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isPackageKey], options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in en {
                if j.stop { break }
                let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isPackageKey])
                if rv?.isDirectory == true { if SearchIndex.skipDirs.contains(u.lastPathComponent) || rv?.isPackage == true || u.pathExtension == "app" { en.skipDescendants() }; continue }
                guard SearchIndex.kind(u.path) != nil else { continue }
                let size = rv?.fileSize ?? 0; let ext = u.pathExtension.lowercased(); if size > (["pdf", "docx", "doc"].contains(ext) ? 400_000_000 : 30_000_000) { continue }
                seen.insert(u.path); set(j) { $0.scanned += 1 }
                let mt = rv?.contentModificationDate?.timeIntervalSince1970 ?? 0
                if let r = SearchIndex.q("SELECT mtime, size, embedded FROM files WHERE path=?", [u.path]).first,
                   abs((r[0] as? Double ?? -1) - mt) < 0.001, (r[1] as? Int64 ?? -1) == Int64(size), (r[2] as? Int64 ?? 0) == 1 { set(j) { $0.unchanged += 1 }; continue }
                work.append((u.path, f, mt, size))
            }
            // forget files that are gone from this folder (index only)
            let gone = SearchIndex.q("SELECT path FROM files WHERE folder=?", [f]).compactMap { $0.first as? String }.filter { !seen.contains($0) }
            for p in gone { forget(p) }; set(j) { $0.removed += gone.count }
        }
        set(j) { $0.toDo = work.count }
        let haveEngine = work.isEmpty ? true : ensureEngineUp(SearchIndex.engine, seconds: 90)
        if !haveEngine { set(j) { $0.meaning = false; $0.note = "The meaning engine didn't start, so files are indexed for exact words only for now." } }
        for (p, folder, mt, size) in work {
            if j.stop { break }
            let name = (p as NSString).lastPathComponent
            set(j) { $0.current = name; $0.note = "" }
            let kind = SearchIndex.kind(p) ?? "text"
            var parts: [String]
            if kind == "photo" {
                let rel = (folder as NSString).lastPathComponent + "/" + String(p.dropFirst(folder.count + 1))
                parts = ["Photo: " + SearchIndex.words(name) + " (in " + ((rel as NSString).deletingLastPathComponent).replacingOccurrences(of: "/", with: " / ") + ")"]
            } else {
                parts = SearchIndex.chunks(SearchIndex.readText(p))
                if parts.isEmpty { parts = ["File: " + SearchIndex.words(name)] }   // still findable by name
            }
            var vecs: [[Float]]? = nil
            if haveEngine {
                vecs = []
                for b in stride(from: 0, to: parts.count, by: 16) {
                    let batch = Array(parts[b..<min(parts.count, b + 16)]).map { "title: \(name) | text: \($0)" }
                    guard let v = SearchIndex.embed(batch) else { vecs = nil; break }
                    vecs! += v
                }
            }
            forget(p)
            SearchIndex.exec("BEGIN")
            for (i, c) in parts.enumerated() {
                SearchIndex.q("INSERT INTO chunks(path, ord, text, emb) VALUES(?,?,?,?)", [p, i, c, vecs.map { SearchIndex.blob($0[i]) } as Any?])
                let id = sqlite3_last_insert_rowid(SearchIndex.db)
                SearchIndex.q("INSERT INTO fts(text, name, path, chunk) VALUES(?,?,?,?)", [c, SearchIndex.words(name), p, id])
            }
            SearchIndex.q("INSERT OR REPLACE INTO files(path, folder, name, kind, mtime, size, chunks, embedded) VALUES(?,?,?,?,?,?,?,?)", [p, folder, name, kind, mt, size, parts.count, vecs == nil ? 0 : 1])
            SearchIndex.exec("COMMIT")
            set(j) { $0.done += 1; $0.chunks += parts.count; if vecs == nil && haveEngine { $0.failed += 1 } }
            log?("{\"file\":\"\(name)\",\"parts\":\(parts.count),\"meaning\":\(vecs != nil)}")
        }
        for f in fs { SearchIndex.q("UPDATE folders SET last_indexed=? WHERE path=?", [Date().timeIntervalSince1970, f]) }
        SearchIndex.lock.lock(); SearchIndex.vecCache = nil; SearchIndex.lock.unlock()
        lastRun = Date()
        set(j) { $0.secs = Date().timeIntervalSince(t0); $0.state = $0.stop ? "stopped" : "done"; $0.current = "" }
    }
    static func forget(_ p: String) {
        SearchIndex.q("DELETE FROM fts WHERE path=?", [p]); SearchIndex.q("DELETE FROM chunks WHERE path=?", [p]); SearchIndex.q("DELETE FROM files WHERE path=?", [p])
    }
}
