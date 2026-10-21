import AppKit
import Foundation

/// Create new files (no approval needed) and edit existing ones (Approve card + backup + Undo).
/// Same PathGuard rules as every other file tool: home folder only, never Library or hidden folders.
@MainActor
enum FileWrite {
    nonisolated static let backups = SUPPORT + "/backups"

    static func encode(_ text: String, ext: String) -> Data? {
        let attr: () -> NSAttributedString = {
            NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)]) }
        let all = { (a: NSAttributedString) in NSRange(location: 0, length: a.length) }
        switch ext {
        case "docx": let a = attr(); return try? a.data(from: all(a), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        case "doc": let a = attr(); return try? a.data(from: all(a), documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
        case "rtf": let a = attr(); return try? a.data(from: all(a), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case "odt": let a = attr(); return try? a.data(from: all(a), documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument])
        // HTML is code: write the model's text exactly as given. (Converting it as "styled text" escaped every tag,
        // so browsers showed the code instead of running the page: the Space Invaders bug, Oct 21.)
        default: return text.data(using: .utf8)
        }
    }
    /// Small models sometimes guess the home folder (/Users/user/...). Map it onto the real home, like the read tools do.
    nonisolated static func fixHome(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.hasPrefix(home + "/"), t != home, let m = t.range(of: "^/(Users|home)/[^/]+/", options: .regularExpression) { return home + "/" + t[m.upperBound...] }
        return t
    }
    static let blocked: Set<String> = ["pages", "numbers", "key", "pdf", "app", "dmg", "zip", "png", "jpg", "jpeg", "heic", "gif"]

    /// Path for a new file: plain names land on the Desktop; .txt is added when there is no extension.
    static func target(_ raw: String) -> Result<String, String> {
        var t = fixHome(raw)
        if t.isEmpty { return .failure("Say what to call the file (for example Desktop/notes.txt).") }
        if !t.contains("/") && !t.hasPrefix("~") { t = "Desktop/" + t }
        if (t as NSString).pathExtension.isEmpty { t += ".txt" }
        switch FileTools2.resolve(t) {
        case .failure(let r): return .failure(FileTools2.refusal(r))
        case .success(let p): return .success(p)
        }
    }

    static func create(path raw: String, content: String) -> [String: Any] {
        let p: String
        switch target(raw) { case .failure(let m): return ["text": "Could not create the file: " + m]; case .success(let x): p = x }
        let ext = (p as NSString).pathExtension.lowercased()
        if ext == "pages" { return ["text": "To make a Pages document, use the pages_new_document tool (it opens Pages and types the text)."] }
        if blocked.contains(ext) { return ["text": "I can't write .\(ext) files. I can make .txt, .md, .docx (Word), .rtf, .html or code files."] }
        let fm = FileManager.default
        if fm.fileExists(atPath: p) { return ["text": "\(AgentTools.short(p)) already exists, so I did not touch it. To change it, use edit_file (the user approves first)."] }
        let parent = (p as NSString).deletingLastPathComponent
        var made: [String] = []
        var walk = parent
        while !fm.fileExists(atPath: walk) { made.insert(walk, at: 0); walk = (walk as NSString).deletingLastPathComponent }
        do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) } catch { return ["text": "Could not make the folder \(AgentTools.short(parent)): \(error.localizedDescription)"] }
        guard let data = encode(content, ext: ext) else { return ["text": "Could not turn the text into a .\(ext) file."] }
        do { try data.write(to: URL(fileURLWithPath: p), options: .withoutOverwriting) } catch { return ["text": "Could not create \(AgentTools.short(p)): \(error.localizedDescription)"] }
        let steps = [UndoStep(op: "trash", from: nil, to: nil, path: p)] + made.reversed().map { UndoStep(op: "removeEmptyFolder", from: nil, to: nil, path: $0) }
        let uid = UndoLog.record(kind: "createFile", summary: "Create \(AgentTools.short(p))", steps: steps)
        if Creations.isWeb(p) {   // web pages and games open in the browser right away, so they run
            _ = Creations.openInBrowser(p)
            return ["text": "DONE: created \(AgentTools.short(p)) (\(content.count) characters) and opened it in \(Creations.browserName()) so it runs. The user also has a Play button. Tell them it is done and where it is.", "undoId": uid?.uuidString ?? "", "files": [p]]
        }
        return ["text": "DONE: created \(AgentTools.short(p)) (\(content.count) characters). Tell the user it is done and where it is. They can say \"undo\" to move it to the Trash.", "undoId": uid?.uuidString ?? "", "files": [p]]
    }

    /// Plan an edit. Nothing is written until the user approves.
    static func planEdit(path raw: String, mode rawMode: String, text: String, find: String?) -> PendingAction {
        let p: String
        switch FileTools2.resolve(fixHome(raw)) {
        case .failure(let r): return .failed(kind: .editFile, summary: FileTools2.refusal(r))
        case .success(let x): p = x
        }
        let ext = (p as NSString).pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: p) else { return .failed(kind: .editFile, summary: "There is no file at \(AgentTools.short(p)). To make a new one, use create_file.") }
        if ext == "pages" { return .failed(kind: .editFile, summary: "I can't edit Pages files directly. I can make a new Pages document with pages_new_document, or edit a Word (.docx) copy.") }
        if blocked.contains(ext) { return .failed(kind: .editFile, summary: "I can't edit .\(ext) files.") }
        let (ok, old) = FileTools2.extractFullText(path: p)
        let current = ok ? old : ""
        if !ok && !old.contains("has no text") { return .failed(kind: .editFile, summary: old) }
        let mode = rawMode.lowercased()
        var new = current; var what = ""
        switch mode {
        case "append", "add", "add_to_end", "end":
            new = current.isEmpty ? text : current + (current.hasSuffix("\n") ? "" : "\n") + text; what = "Add this to the end:\n\(text)"
        case "prepend", "start", "top", "add_to_top":
            new = text + "\n" + current; what = "Add this at the top:\n\(text)"
        case "replace", "find_replace", "replace_text":
            guard let f = find, !f.isEmpty else { return .failed(kind: .editFile, summary: "Say which text to replace (find) and what to put instead (text).") }
            guard current.contains(f) else { return .failed(kind: .editFile, summary: "The text “\(f)” is not in \(AgentTools.short(p)). Nothing was changed. Read the file first and copy the exact words.") }
            let n = current.components(separatedBy: f).count - 1
            new = current.replacingOccurrences(of: f, with: text); what = "Replace \(n == 1 ? "this" : "these \(n)") :\n“\(f)”\nwith:\n“\(text)”"
        case "overwrite", "rewrite", "replace_all", "whole":
            new = text; what = "Replace the whole file (\(current.count) characters now) with this new text (\(text.count) characters):\n\(text)"
        default:
            return .failed(kind: .editFile, summary: "Unknown edit mode “\(rawMode)”. Use append, prepend, replace or overwrite.")
        }
        guard let data = encode(new, ext: ext) else { return .failed(kind: .editFile, summary: "Could not write .\(ext) files.") }
        var warns: [String] = ["A backup of the current file is kept, and Undo puts it back."]
        if ["docx", "doc", "rtf", "odt"].contains(ext) { warns.append("Note: this rewrites the document as plain styled text, so special formatting (images, tables, colours) may be lost. Undo brings the original back.") }
        var a = PendingAction(id: UUID(), kind: .editFile, title: "Edit \(AgentTools.short(p))", summary: what, transfers: [], warnings: warns, phase: .pending, resultText: nil, undoID: nil, ensureFolder: nil)
        a.editPath = p; a.editData = data
        return a
    }

    static func runEdit(_ action: PendingAction) -> PendingAction {
        var action = action
        guard let p = action.editPath, let data = action.editData, case .success(let path) = PathGuard.accept(p) else {
            action.phase = .failed; action.resultText = "That path is no longer allowed."; return action }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: backups, withIntermediateDirectories: true)
        let bak = backups + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
        do { try fm.copyItem(atPath: path, toPath: bak) } catch { action.phase = .failed; action.resultText = "Could not back up the file first, so nothing was changed: \(error.localizedDescription)"; return action }
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch { action.phase = .failed; action.resultText = "Could not save the edit: \(error.localizedDescription). Nothing was changed."; return action }
        guard let id = UndoLog.record(kind: "editFile", summary: "edit of \(AgentTools.short(path))", steps: [UndoStep(op: "restoreFile", from: bak, to: path, path: nil)]) else {
            try? fm.removeItem(atPath: path); try? fm.copyItem(atPath: bak, toPath: path)
            action.phase = .failed; action.resultText = "Couldn't save the undo log, so I put the original back."; return action }
        action.phase = .done; action.undoID = id
        action.resultText = "DONE: saved the edit to \(AgentTools.short(path)). A backup was kept; say \"undo\" to put the old version back."
        return action
    }

    /// Undo of an edit: put the backup back (the edited version is kept next to the backups, just in case).
    nonisolated static func restore(from bak: String, to raw: String) -> String? {
        guard bak.hasPrefix(backups + "/"), FileManager.default.fileExists(atPath: bak) else { return "The backup for this edit is missing." }
        guard case .success(let path) = PathGuard.accept(raw) else { return "Refused to undo into \(raw)." }
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { try? fm.copyItem(atPath: path, toPath: bak + ".edited-version") }
        do {
            let d = try Data(contentsOf: URL(fileURLWithPath: bak))
            try d.write(to: URL(fileURLWithPath: path), options: .atomic)
            return nil
        } catch { return "Couldn't put the old version back: \(error.localizedDescription)" }
    }

    // ---- Pages ----
    nonisolated static func asText(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    /// New blank Pages document with the given text typed in. Optional save path (.pages).
    /// Automation permission for Pages, checked WITHOUT showing the macOS prompt.
    nonisolated static func pagesPermission() -> String {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.iWork.Pages")
        let st = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        switch Int(st) { case 0: return "allowed"; case -1743: return "denied"; case -1744: return "notAskedYet"; case -600: return "pagesNotRunning"; default: return "status \(st)" }
    }
    nonisolated static let scriptQueue = DispatchQueue(label: "modelpicker.applescript")
    nonisolated static func pagesNew(text: String, savePath: String?) -> [String: Any] {
        var save = ""
        var savedTo: String?
        if let sp = savePath?.trimmingCharacters(in: .whitespacesAndNewlines), !sp.isEmpty {
            var t = fixHome(sp); if !t.contains("/") && !t.hasPrefix("~") { t = "Desktop/" + t }
            if (t as NSString).pathExtension.lowercased() != "pages" { t = ((t as NSString).deletingPathExtension) + ".pages" }
            let tt = t
            switch mainSync({ FileTools2.resolve(tt) }) {
            case .failure(let r): return ["text": "Could not save there: " + mainSync { FileTools2.refusal(r) }]
            case .success(let p):
                if FileManager.default.fileExists(atPath: p) { return ["text": "\(p) already exists, so I did not overwrite it. Pick another name."] }
                savedTo = p; save = "\n  save d in POSIX file \(asText(p))"
            }
        }
        let src = """
        with timeout of 300 seconds
        tell application "Pages"
          activate
          set d to make new document
          delay 0.5
          set body text of d to \(asText(text))\(save)
          return name of d
        end tell
        end timeout
        """
        var err: NSDictionary?
        var r: NSAppleEventDescriptor?
        scriptQueue.sync { r = NSAppleScript(source: src)?.executeAndReturnError(&err) }
        if let e = err {
            let n = (e[NSAppleScript.errorNumber] as? Int) ?? 0
            if n == -1743 || n == -1744 {
                return ["text": "PERMISSION_DENIED: macOS has not allowed Model Picker to control Pages yet. Tell the user: open System Settings > Privacy & Security > Automation, find Model Picker, and turn on Pages. Then ask again. (Nothing was written.)"]
            }
            if n == -1712, pagesPermission() != "allowed" {
                return ["text": "PERMISSION_PENDING: macOS is showing a box that says “Model Picker wants access to control Pages”. Tell the user plainly: click Allow on that box, then ask again. Nothing was written yet."]
            }
            return ["text": "Pages did not do it (error \(n): \(e[NSAppleScript.errorMessage] ?? "unknown")). Nothing was saved."]
        }
        let name = r?.stringValue ?? "Untitled"
        var out = "DONE: opened a new blank Pages document (“\(name)”) and typed \(text.count) characters at the top: “\(text.count > 200 ? String(text.prefix(200)) + "…" : text)”."
        if let s = savedTo { out += " Saved it to \(s)." } else { out += " It is not saved yet; it is open in Pages for the user." }
        return ["text": out + " Tell the user it is done."]
    }
}
