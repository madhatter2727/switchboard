import Foundation
import EventKit

/// Safe file tools for Agent mode. Same rules as Ask My Mac's PathGuard: only inside the home folder,
/// never ~/Library, never hidden (dot) folders. Nothing here deletes. Changing tools only run after
/// the window got an explicit Approve.
enum AgentTools {
    static let changing: Set<String> = PortTools.changingNames

    static func guardPath(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.contains("\0") || t.contains("\n") { return nil }
        t = (t as NSString).expandingTildeInPath
        // Small models sometimes guess the home folder (/Users/user/..., /home/user/...). Map it onto Tara's home.
        if !t.hasPrefix(home + "/") && t != home, let m = t.range(of: "^/(Users|home)/[^/]+/", options: .regularExpression) { t = home + "/" + t[m.upperBound...] }
        if !t.hasPrefix("/") { t = home + "/" + t }
        // resolve symlinks on the deepest existing ancestor, so links cannot escape home
        var url = URL(fileURLWithPath: t).standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { tail.insert(url.lastPathComponent, at: 0); url.deleteLastPathComponent() }
        var p = url.resolvingSymlinksInPath().path
        for c in tail { p += "/" + c }
        let h = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        guard p == h || p.hasPrefix(h + "/") else { return nil }
        let rel = p.dropFirst(h.count).split(separator: "/")
        if rel.first == "Library" { return nil }
        if rel.contains(where: { $0.hasPrefix(".") }) { return nil }
        return p
    }
    static func short(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
    static func args(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }
    static func strList(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let s = v as? String { return [s] }
        return []
    }
    static func uniqueDest(_ dir: String, _ name: String) -> String {
        var dest = dir + "/" + name; var n = 2
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: dest) {
            dest = dir + "/" + base + " \(n)" + (ext.isEmpty ? "" : "." + ext); n += 1 }
        return dest
    }
    static func intArg(_ v: Any?) -> Int? { if let i = v as? Int { return i }; if let d = v as? Double { return Int(d) }; if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }; return nil }
    /// Pages a long list instead of cutting it: returns one page plus how to get the next one.
    static func page(_ rows: [String], _ a: [String: Any], _ size: Int) -> String {
        let off = max(0, min(rows.count, intArg(a["offset"]) ?? 0)), end = min(rows.count, off + size)
        var out = rows[off..<end].joined(separator: "\n")
        if off > 0 || end < rows.count { out += "\n[Items \(off + 1)–\(end) of \(rows.count).\(end < rows.count ? " MORE: call again with offset \(end) to see the rest." : " That is the end of the list.")]" }
        return out
    }
    static func fmtSize(_ n: Int) -> String { n < 1024 ? "\(n) B" : n < 1_048_576 ? "\(n / 1024) KB" : String(format: "%.1f MB", Double(n) / 1_048_576) }

    /// Read-only tools run now. Changing tools return a preview only ("pending": true).
    static func run(_ name: String, _ argText: String) -> [String: Any] {
        let a = args(argText); let fm = FileManager.default
        if let r = PortTools.run(name, a) { return r }
        switch name {
        case "list_folder":
            guard let p = guardPath(a["path"] as? String ?? ""), let items = try? fm.contentsOfDirectory(atPath: p) else { return ["text": "Cannot open that folder (it must be inside your home folder, not Library or hidden)."] }
            let rows = items.filter { !$0.hasPrefix(".") }.sorted().map { n -> String in
                var d: ObjCBool = false; fm.fileExists(atPath: p + "/" + n, isDirectory: &d); return (d.boolValue ? "[folder] " : "") + n }
            return ["text": rows.isEmpty ? "The folder is empty." : page(rows, a, 500)]
        case "search_files":
            let q = (a["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return ["text": "Missing query."] }
            let (_, out) = runCmd("/usr/bin/mdfind", ["-onlyin", home, "-name", q])
            let paths = out.split(separator: "\n").map(String.init).compactMap { guardPath($0) }
            return ["text": paths.isEmpty ? "No matching files." : page(paths.map(short), a, 200)]
        case "list_files_by_date":
            let days = (a["days_back"] as? Int) ?? Int("\(a["days_back"] ?? "7")") ?? 7
            guard let p = guardPath((a["folder"] as? String) ?? "Desktop"), let en = fm.enumerator(atPath: p) else { return ["text": "Cannot open that folder."] }
            let cutoff = Date().addingTimeInterval(-Double(max(days, 0)) * 86400 - (days == 0 ? 0 : 0))
            let start = days == 0 ? Calendar.current.startOfDay(for: Date()) : cutoff
            let want = (a["name_contains"] as? String)?.lowercased()
            var rows: [(Date, String)] = []
            while let f = en.nextObject() as? String {
                if f.hasPrefix(".") || f.contains("/.") { continue }
                if en.level > 2 { en.skipDescendants() }
                let full = p + "/" + f
                guard let at = try? fm.attributesOfItem(atPath: full), let m = at[.modificationDate] as? Date, m >= start else { continue }
                if at[.type] as? FileAttributeType == .typeDirectory { continue }
                if let w = want, !f.lowercased().contains(w) { continue }
                rows.append((m, f + "  (" + fmtSize((at[.size] as? Int) ?? 0) + ", " + DateFormatter.localizedString(from: m, dateStyle: .medium, timeStyle: .short) + ")"))
            }
            rows.sort { $0.0 > $1.0 }
            return ["text": rows.isEmpty ? "No files changed in that time." : page(rows.map { $0.1 }, a, 300)]
        case "file_info":
            guard let p = guardPath(a["path"] as? String ?? ""), let at = try? fm.attributesOfItem(atPath: p) else { return ["text": "Cannot read that path."] }
            return ["text": "\(short(p)): \(at[.type] as? String ?? ""), \(fmtSize((at[.size] as? Int) ?? 0)), modified \(at[.modificationDate] ?? "")"]
        case "read_file_text":
            // Whole file, no size cap. Optional offset + max_chars read one exact slice (the window pages big files).
            guard let p = guardPath(a["path"] as? String ?? "") else { return ["text": "Cannot read that file (it must be inside your home folder, not Library or hidden)."] }
            let (ok, full) = mainSync { FileTools2.extractFullText(path: p) }
            if !ok { return ["text": full] }
            let total = full.count
            let off = max(0, min(total, intArg(a["offset"]) ?? 0))
            let want = intArg(a["max_chars"]).map { max(1, $0) } ?? (total - off)
            let sIdx = full.index(full.startIndex, offsetBy: off), eIdx = full.index(sIdx, offsetBy: min(want, total - off))
            let end = off + full.distance(from: sIdx, to: eIdx)
            let head = "FILE \(short(p)) — characters \(off)–\(end) of \(total)" + (off == 0 && end == total ? " (the whole file)" : "")
            let tail = end < total ? "\n[MORE: \(total - end) characters remain. Call read_file_text again with offset \(end) to keep reading.]" : "\n[END OF FILE]"
            return ["text": head + "\n" + String(full[sIdx..<eIdx]) + tail, "total": total, "start": off, "end": end, "path": short(p)]
        case "list_calendar_events": return ["text": calendarEvents(a)]
        case "move_items":
            let dest = a["destination_folder"] as? String ?? ""
            guard let dp = guardPath(dest) else { return ["text": "That destination is not allowed."] }
            let ps = strList(a["paths"]).compactMap { guardPath($0) }.filter { fm.fileExists(atPath: $0) }
            guard !ps.isEmpty else { return ["text": "None of those files exist or are allowed."] }
            let lines = ps.map { "• " + short($0) }.joined(separator: "\n")
            return ["pending": true, "preview": "Move \(ps.count) item(s) into \(short(dp)):\n" + lines + "\nNothing is overwritten.", "text": "Waiting for the user to approve this move. Nothing has changed yet."]
        case "rename_item":
            guard let p = guardPath(a["path"] as? String ?? ""), fm.fileExists(atPath: p), let nn = a["new_name"] as? String, !nn.isEmpty, !nn.contains("/"), !nn.hasPrefix(".") else { return ["text": "Cannot rename: check the path and use a plain new file name."] }
            return ["pending": true, "preview": "Rename \(short(p))\nto “\(nn)”.", "text": "Waiting for the user to approve this rename. Nothing has changed yet."]
        default: return ["text": "Unknown tool \(name)."]
        }
    }

    // ---- READ-ONLY calendar (same idea as Ask My Mac: EventKit, never writes) ----
    static let store = EKEventStore()
    static func calendarEvents(_ a: [String: Any]) -> String {
        var status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            store.requestFullAccessToEvents { _, _ in sem.signal() }
            if sem.wait(timeout: .now() + 25) == .timedOut {
                return "PERMISSION_PENDING: macOS is asking Tara to allow calendar access. Tell her plainly: click Allow on the pop-up on her screen, then ask again. No events were read."
            }
            status = EKEventStore.authorizationStatus(for: .event)
        }
        guard status == .fullAccess else {
            return "PERMISSION_DENIED: Model Picker does not have calendar access. Tell Tara plainly to open System Settings > Privacy & Security > Calendars and turn on Model Picker, then ask again."
        }
        let cal = Calendar.current; let now = Date(); let sod = cal.startOfDay(for: now)
        var start = sod, end = cal.date(byAdding: .day, value: 1, to: sod)!, label = "Today"
        let r = (a["range"] as? String ?? "today").lowercased().replacingOccurrences(of: " ", with: "_")
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
        if let sd = a["start_date"] as? String, let d = iso.date(from: String(sd.prefix(10))) {
            start = cal.startOfDay(for: d); label = "From " + sd.prefix(10)
            if let ed = a["end_date"] as? String, let e = iso.date(from: String(ed.prefix(10))) { end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e))!; label += " to " + ed.prefix(10) }
            else { end = cal.date(byAdding: .day, value: 1, to: start)! }
        } else if r == "tomorrow" { start = cal.date(byAdding: .day, value: 1, to: sod)!; end = cal.date(byAdding: .day, value: 1, to: start)!; label = "Tomorrow" }
        else if r == "this_week" || r == "week" { if let w = cal.dateInterval(of: .weekOfYear, for: now) { start = w.start; end = w.end }; label = "This week" }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: pred).filter { $0.status != .canceled }.sorted { $0.startDate < $1.startDate }
        let multi = end.timeIntervalSince(start) > 86400 * 1.5
        let df = DateFormatter(); df.dateStyle = .none; df.timeStyle = .short
        let dd = DateFormatter(); dd.dateFormat = "EEE MMM d"
        var lines: [String] = []; var seen = Set<String>()
        for e in events {
            let key = "\(e.eventIdentifier ?? "")|\(e.startDate.timeIntervalSince1970)"; if !seen.insert(key).inserted { continue }
            let when = e.isAllDay ? (multi ? dd.string(from: e.startDate) + " all day" : "All day") : (multi ? dd.string(from: e.startDate) + " " : "") + df.string(from: e.startDate) + "–" + df.string(from: e.endDate)
            lines.append(when + " — " + (e.title ?? "(No title)") + (e.calendar != nil ? " (" + e.calendar.title + ")" : ""))
        }
        return label + " (" + dd.string(from: start) + "):\n" + (lines.isEmpty ? "No events." : lines.joined(separator: "\n"))
    }

    /// Runs a changing tool AFTER the user pressed Approve.
    static func apply(_ name: String, _ argText: String) -> String {
        let a = args(argText); let fm = FileManager.default
        if name == "move_items" {
            guard let dp = guardPath(a["destination_folder"] as? String ?? "") else { return "Not allowed." }
            try? fm.createDirectory(atPath: dp, withIntermediateDirectories: true)
            var done: [String] = []
            for p in strList(a["paths"]).compactMap({ guardPath($0) }) where fm.fileExists(atPath: p) {
                let dest = uniqueDest(dp, (p as NSString).lastPathComponent)
                do { try fm.moveItem(atPath: p, toPath: dest); done.append(short(dest)) } catch { return "Move failed: \(error.localizedDescription)" }
            }
            return done.isEmpty ? "Nothing was moved." : "Moved to: " + done.joined(separator: ", ")
        }
        if name == "rename_item", let p = guardPath(a["path"] as? String ?? ""), let nn = a["new_name"] as? String, !nn.contains("/") {
            let dest = uniqueDest((p as NSString).deletingLastPathComponent, nn)
            do { try fm.moveItem(atPath: p, toPath: dest); return "Renamed to " + short(dest) } catch { return "Rename failed: \(error.localizedDescription)" }
        }
        return "Unknown action."
    }
}
