import Foundation

/// "Open the gdd document in my test folder" without a model.
/// Splits the request into a document name and an optional folder, resolves the folder
/// (Desktop and home first), and matches the name against file basenames only.
/// Opens only when exactly one file matches. (Oct 21 2026 fix: the old path ran a
/// whole-home Spotlight content search on the full sentence and opened the first PDF.)
enum DocFinder {
    struct Request: Equatable {
        var name: String          // lowercased words to match in the basename ("" = any file of the type)
        var folderPhrase: String? // what the user called the folder
        var types: Set<String>    // extension hint from "pdf", "word doc", ...
    }
    enum Outcome {
        case one(String)
        case several([String], String)   // paths, where we looked
        case none(String)                // where we looked
        case folderNotFound(String)
    }

    static var dryRun: Bool {
        CommandLine.arguments.contains("--dry-run") || ProcessInfo.processInfo.environment["MP_DRYRUN"] == "1"
    }
    static let home = NSHomeDirectory()

    private static let notSimple = [" and ", " then ", "summar", "tell me", "explain", "what ", "why ", "how ",
                                    "?", " with ", "edit", "change", "rewrite", "translate", "compare", "read ", " about "]
    private static let typeWords: [String: Set<String>] = [
        "pdf": ["pdf"], "pdfs": ["pdf"], "markdown": ["md", "markdown"], "md": ["md", "markdown"],
        "word": ["doc", "docx"], "docx": ["docx"], "spreadsheet": ["xlsx", "xls", "numbers", "csv"],
        "excel": ["xlsx", "xls"], "csv": ["csv"], "txt": ["txt"], "text": ["txt", "md", "rtf"],
        "slides": ["key", "pptx", "ppt"], "presentation": ["key", "pptx", "ppt"], "pages": ["pages"],
        "image": ["png", "jpg", "jpeg", "heic", "gif", "webp"], "photo": ["png", "jpg", "jpeg", "heic"],
        "screenshot": ["png", "jpg"]
    ]
    private static let genericWords: Set<String> = ["document", "documents", "doc", "docs", "file", "files", "the", "my", "a", "an", "that", "this"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "pages", "txt", "md", "markdown", "rtf", "rtfd",
                                                  "key", "numbers", "xlsx", "xls", "ppt", "pptx", "csv", "odt", "html", "htm"]
    private static let packageExtensions: Set<String> = ["pages", "key", "numbers", "rtfd"]
    private static let blockedDirs: Set<String> = ["node_modules", ".git", "library", "__pycache__", ".venv", "venv"]

    /// Nil when this isn't a simple "open <name> [in <folder>]" request.
    static func parse(_ query: String) -> Request? {
        var q = " " + query.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "").replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "\"", with: "") + " "
        for w in notSimple where q.contains(w) { return nil }
        q = q.trimmingCharacters(in: .whitespaces)
        var namePart = q, folder: String? = nil
        // First location word splits name from folder: "gdd document | in my test folder"
        if let r = q.range(of: #"\s+(in|inside|on|from|under|within)\s+"#, options: .regularExpression) {
            namePart = String(q[..<r.lowerBound]); folder = String(q[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
            if folder?.isEmpty == true { return nil }
        }
        var types = Set<String>(); var words: [String] = []
        for raw in namePart.split(separator: " ") {
            let w = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".,!;:'"))
            if w.isEmpty || genericWords.contains(w) { continue }
            if let t = typeWords[w] { types.formUnion(t); continue }
            words.append(w)
        }
        if words.count > 4 { return nil }                       // long phrase: not a filename, let the model handle it
        if words.isEmpty && (types.isEmpty || folder == nil) { return nil }
        return Request(name: words.joined(separator: " "), folderPhrase: folder, types: types)
    }

    /// "my test folder" -> ~/Desktop/Test. Supports chains: "the test folder on my desktop".
    static func resolveFolder(_ phrase: String) -> String? {
        var chain = phrase.replacingOccurrences(of: #"\s+(in|inside|on|under|within)\s+"#, with: "|", options: .regularExpression)
            .split(separator: "|").map { clean(String($0)) }.filter { !$0.isEmpty }
        guard let last = chain.popLast() else { return nil }
        guard var base = resolveTop(last) else { return nil }
        while let next = chain.popLast() {
            guard let child = childDir(base, named: next) else { return nil }
            base = child
        }
        return base
    }
    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: CharacterSet(charactersIn: " .!,"))
        for p in ["the ", "my ", "our ", "your "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        for s in [" folder", " directory", " dir"] where t.hasSuffix(s) { t = String(t.dropLast(s.count)) }
        if t.hasPrefix("~/") { t = String(t.dropFirst(2)) }
        return t.trimmingCharacters(in: .whitespaces)
    }
    private static func resolveTop(_ name: String) -> String? {
        let special = ["desktop": "Desktop", "home": "", "documents": "Documents", "docs": "Documents",
                       "downloads": "Downloads", "pictures": "Pictures", "movies": "Movies", "music": "Music"]
        if let s = special[name] { return s.isEmpty ? home : home + "/" + s }
        if name.contains("/") {   // "projects/model-picker"
            var base = home
            for comp in name.split(separator: "/") { guard let c = childDir(base, named: String(comp)) else { return nil }; base = c }
            return base
        }
        for root in [home + "/Desktop", home, home + "/Documents", home + "/Downloads"] {
            if let c = childDir(root, named: name) { return c }
        }
        return nil
    }
    private static func childDir(_ base: String, named name: String) -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for n in items where !n.hasPrefix(".") && n.caseInsensitiveCompare(name) == .orderedSame {
            var d = ObjCBool(false)
            if FileManager.default.fileExists(atPath: base + "/" + n, isDirectory: &d), d.boolValue { return base + "/" + n }
        }
        return nil
    }

    static func nameMatches(_ path: String, _ req: Request) -> Bool {
        let base = (path as NSString).lastPathComponent.lowercased()
        let ext = (base as NSString).pathExtension
        if !req.types.isEmpty && !req.types.contains(ext) { return false }
        if req.name.isEmpty { return true }
        let stem = (base as NSString).deletingPathExtension
        let squashed = stem.replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
        let whole = req.name.replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
        if !whole.isEmpty && squashed.contains(whole) { return true }       // "mac mini" ~ "mac-mini"
        return req.name.components(separatedBy: " ").allSatisfy { stem.contains($0) }
    }

    /// Every file under `root` (no cap), skipping hidden items, dependency caches, and package insides.
    private static func walk(_ root: String) -> [String] {
        var out: [String] = []
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        for case let url as URL in en {
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if v?.isDirectory == true {
                if blockedDirs.contains(name.lowercased()) || name.hasSuffix(".app") { en.skipDescendants(); continue }
                if !packageExtensions.contains(url.pathExtension.lowercased()) { continue }
            }
            out.append(url.path)
        }
        return out
    }

    private static func spotlightNames(_ req: Request) -> [String] {
        let key: String = req.name.components(separatedBy: " ").max(by: { $0.count < $1.count }) ?? ""
        guard !key.isEmpty else { return [] }
        let lit = key.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "*", with: "")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", home, "kMDItemFSName == '*\(lit)*'cd"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).map(String.init).filter { path in
            guard case .success = PathGuard.accept(path) else { return false }
            let comps = path.lowercased().split(separator: "/")
            if comps.contains(where: { $0.hasPrefix(".") || blockedDirs.contains(String($0)) || $0.hasSuffix(".app") && $0 != comps.last }) { return false }
            var d = ObjCBool(false); FileManager.default.fileExists(atPath: path, isDirectory: &d)
            return !d.boolValue || packageExtensions.contains((path as NSString).pathExtension.lowercased())
        }
    }

    static func find(_ req: Request) -> Outcome {
        var scope = "your home folder"; var candidates: [String]
        if let phrase = req.folderPhrase {
            guard let dir = resolveFolder(phrase) else { return .folderNotFound(phrase) }
            scope = short(dir)
            candidates = walk(dir)
        } else {
            candidates = spotlightNames(req)
        }
        var hits = candidates.filter { nameMatches($0, req) }
        // A document beats an image or code file with the same name.
        let docs = hits.filter { documentExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        if !docs.isEmpty && req.types.isEmpty { hits = docs }
        hits = Array(Set(hits)).sorted { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            return da != db ? da < db : a.lowercased() < b.lowercased() }
        switch hits.count {
        case 0: return .none(scope)
        case 1: return .one(hits[0])
        default: return .several(hits, scope)
        }
    }

    static func short(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

    /// Bridge reply for the web page. handled=false means "let the model with file tools take it" (note says why).
    static func handle(query: String, req: Request) async -> [String: Any] {
        let label = req.name.isEmpty ? (req.types.sorted().first ?? "file") : req.name
        // "open safari": a plain app name with no folder or file type opens the app.
        if req.folderPhrase == nil && req.types.isEmpty && !req.name.contains(" ") {
            for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"] {
                if let n = try? FileManager.default.contentsOfDirectory(atPath: dir),
                   let app = n.first(where: { $0.lowercased() == req.name + ".app" }) {
                    if dryRun { return ["handled": true, "text": "Would open the app \(app) (dry run).", "tools": ["open_item"], "dryRun": true] }
                    return ["handled": true, "text": await FileTools2.openItem(dir + "/" + app), "tools": ["open_item"]]
                }
            }
        }
        switch find(req) {
        case .one(let path):
            if dryRun { return ["handled": true, "text": "Would open \(short(path)) (dry run, nothing opened).", "files": [path], "tools": ["open_item"], "dryRun": true] }
            let t = await FileTools2.openItem(path)
            return ["handled": true, "text": t, "files": [path], "tools": ["open_item"]]
        case .several(let paths, let scope):
            return ["handled": true, "text": "I found \(paths.count) files matching “\(label)” in \(scope), so I didn't open any. Press Open on the one you want.", "files": paths, "tools": ["search_files"]]
        case .none(let scope):
            var r: [String: Any] = ["handled": false, "note": "I couldn't find a file matching “\(label)” in \(scope). Asking the model to look with its file tools…"]
            if let ph = req.folderPhrase, let dir = resolveFolder(ph) {
                r["hint"] = "Note: the user's \"\(ph)\" is the folder \(dir). A filename search there found no file named like \"\(label)\". Use list_folder on \(dir) first, then tell the user plainly if it isn't there."
            }
            return r
        case .folderNotFound(let phrase):
            return ["handled": false, "note": "I couldn't find a folder called “\(clean(phrase))” on your Desktop or in your home folder. Asking the model to look with its file tools…"]
        }
    }
}
