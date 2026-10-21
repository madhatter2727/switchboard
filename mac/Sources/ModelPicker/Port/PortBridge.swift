import Foundation
import AppKit
import EventKit
import WebKit
import Speech
import AVFoundation

/// Runs main-actor Ask My Mac logic from the bridge's background threads.
func mainSync<T>(_ f: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(f) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(f) }
}
func mainAwait<T>(_ f: @escaping @MainActor () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0); var out: T?
    Task { @MainActor in out = await f(); sem.signal() }
    sem.wait(); return out!
}

/// Ported from Ask My Mac: same planning, same approve step, same undo log.
enum PortTools {
    static let lock = NSLock()
    static var pendings: [String: PendingAction] = [:]
    static let changingNames: Set<String> = ["move_items", "rename_item", "copy_items", "create_folder", "trash_items", "create_calendar_event", "edit_file"]

    private static func str(_ a: [String: Any], _ keys: [String]) -> String? {
        for k in keys { if let s = a[k] as? String { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { return t } } }
        return nil
    }
    private static func list(_ a: [String: Any]) -> [String] {
        for k in ["paths", "files"] {
            if let l = a[k] as? [Any] { let r = l.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }; if !r.isEmpty { return r } }
            if let s = a[k] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("["), let d = t.data(using: .utf8), let l = try? JSONSerialization.jsonObject(with: d) as? [Any] { return l.compactMap { $0 as? String } }
                if !t.isEmpty { return [t] } }
        }
        if let p = str(a, ["path"]) { return [p] }
        return []
    }
    private static func pend(_ action: PendingAction) -> [String: Any] {
        guard action.phase == .pending else { return ["text": action.previewText] }
        lock.lock(); pendings[action.id.uuidString] = action; lock.unlock()
        return ["pending": true, "pendingId": action.id.uuidString, "preview": action.previewText + (action.kind == .editFile ? "" : "\nNothing is overwritten and nothing is permanently deleted."), "text": "Waiting for the user to approve. Nothing has changed yet."]
    }

    /// nil = not one of the ported tools.
    static func run(_ name: String, _ a: [String: Any]) -> [String: Any]? {
        switch name {
        case "move_items":
            return pend(mainSync { ActionCenter.planMove(paths: list(a), destinationFolder: str(a, ["destination_folder", "destination", "folder"]) ?? "") })
        case "copy_items":
            return pend(mainSync { ActionCenter.planCopy(paths: list(a), destinationFolder: str(a, ["destination_folder", "destination", "folder"]) ?? "") })
        case "rename_item":
            return pend(mainSync { ActionCenter.planRename(path: str(a, ["path"]) ?? "", newName: str(a, ["new_name", "newName", "name"]) ?? "") })
        case "create_folder":
            return pend(mainSync { ActionCenter.planCreateFolder(path: str(a, ["path"]) ?? "") })
        case "trash_items":
            return pend(mainSync { ActionCenter.planTrash(paths: list(a)) })
        case "create_calendar_event":
            let t = str(a, ["title", "name", "summary"]) ?? "", s = str(a, ["start", "start_time"]) ?? "", e = str(a, ["end", "end_time"]) ?? ""
            return pend(mainAwait { await ActionCenter.planCalendarEvent(title: t, start: s, end: e) })
        case "create_file":
            let p = str(a, ["path", "file", "name", "filename"]) ?? ""
            let c = (a["content"] as? String) ?? (a["text"] as? String) ?? (a["contents"] as? String) ?? ""
            return mainSync { FileWrite.create(path: p, content: c) }
        case "edit_file":
            let p = str(a, ["path", "file"]) ?? ""
            let m = str(a, ["mode", "how"]) ?? ((a["find"] as? String).map { _ in "replace" } ?? "append")
            let t = (a["text"] as? String) ?? (a["content"] as? String) ?? (a["new_text"] as? String) ?? (a["replace_with"] as? String) ?? ""
            let f = (a["find"] as? String) ?? (a["old_text"] as? String)
            return pend(mainSync { FileWrite.planEdit(path: p, mode: m, text: t, find: f) })
        case "pages_new_document":
            let t = (a["text"] as? String) ?? (a["content"] as? String) ?? ""
            let s = str(a, ["save_path", "path", "save_as"])
            return FileWrite.pagesNew(text: t, savePath: s)
        case "open_item":
            let t = str(a, ["target", "path", "name"]) ?? ""
            return ["text": mainAwait { await FileTools2.openItem(t) }]
        case "reminders":
            return ["text": mainAwait { await CalendarTools.reminders() }]
        case "ask_photo_reader":
            let p = str(a, ["path"]) ?? "", q = str(a, ["question"]) ?? "Describe this image."
            return ["text": mainAwait { await FileTools2.askPhotoReader(path: p, question: q) }]
        case "calendar_events":
            let s = str(a, ["start", "from", "start_time"]) ?? "", e = str(a, ["end", "to", "end_time"]) ?? ""
            return ["text": mainAwait { await CalendarTools.events(from: s, to: e) }]
        default: return nil
        }
    }

    /// The user pressed Approve. Runs exactly what was previewed.
    static func apply(pendingId: String) -> [String: Any] {
        lock.lock(); let p = pendings.removeValue(forKey: pendingId); lock.unlock()
        guard let action = p else { return ["text": "That action is no longer waiting (nothing was changed).", "ok": false] }
        let done = mainSync { ActionCenter.execute(action) }
        return ["text": done.resultText ?? (done.phase == .done ? "Done." : "Nothing changed."), "ok": done.phase == .done, "undoId": done.undoID?.uuidString ?? ""]
    }
    static func cancel(pendingId: String) { lock.lock(); pendings.removeValue(forKey: pendingId); lock.unlock() }

    // ---- other operations the window and menu call ----
    static func handle(_ op: String, _ d: [String: Any]) -> [String: Any]? {
        switch op {
        case "undoLast":
            let r = mainSync { UndoLog.undoLast() }
            return ["ok": r.ok, "text": r.message]
        case "undoInfo": return ["has": mainSync { UndoLog.hasEntries }]
        case "preroute":
            let t = d["text"] as? String ?? ""
            guard let route = PreRouter.match(t) else { return ["handled": false] }
            if case .openDocument(let q) = route, let req = DocFinder.parse(q) {
                return mainAwait { await DocFinder.handle(query: q, req: req) }
            }
            let m = mainAwait { await PreRouter.perform(route) }
            var out: [String: Any] = ["handled": true, "text": m.text, "files": m.filePaths, "tools": m.toolNames]
            if let p = m.pending { let r = pend(p); out["pending"] = r["pending"] ?? false; out["pendingId"] = r["pendingId"] ?? ""; out["preview"] = r["preview"] ?? p.previewText }
            return out
        case "calList":
            return mainAwait {
                guard await CalendarTools.ensureRead() else { return ["denied": true, "text": CalendarTools.denialEvents] }
                let cals = CalendarTools.store.calendars(for: .event)
                Settings.shared.mergeNewCalendars(cals.map(\.calendarIdentifier))
                return ["calendars": cals.map { ["id": $0.calendarIdentifier, "title": $0.title, "source": $0.source?.title ?? "", "on": Settings.shared.isCalendarEnabled($0.calendarIdentifier)] as [String: Any] }]
            }
        case "calSet":
            let id = d["id"] as? String ?? "", on = d["on"] as? Bool ?? true
            mainSync { Settings.shared.setCalendarEnabled(id, isOn: on, allIdentifiers: CalendarTools.store.calendars(for: .event).map(\.calendarIdentifier)) }
            return ["ok": true]
        case "openPath":
            let p = d["path"] as? String ?? ""
            guard case .success(let path) = PathGuard.accept(p) else { return ["ok": false] }
            NSWorkspace.shared.open(URL(fileURLWithPath: path)); return ["ok": true]
        case "openInBrowser":
            let p = d["path"] as? String ?? ""
            return mainSync {
                guard let path = Creations.resolve(p) else { return ["ok": false, "text": "I couldn't find \(p)."] }
                if d["dry"] != nil { return ["ok": true, "path": path] }   // just find the file (Show in Finder)
                let ok = Creations.openInBrowser(path)
                return ["ok": ok, "path": path, "browser": Creations.browserName()] }
        case "saveCreation":
            let name = d["name"] as? String ?? "creation", html = d["html"] as? String ?? ""
            return mainSync { Creations.save(name: name, html: html).map { ["ok": true, "path": $0] } ?? ["ok": false] }
        case "revealPath":
            let p = d["path"] as? String ?? ""
            guard case .success(let path) = PathGuard.accept(p) else { return ["ok": false] }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]); return ["ok": true]
        case "pickImage":
            return mainSync {
                let pan = NSOpenPanel(); pan.allowedContentTypes = [.image]; pan.canChooseDirectories = false
                pan.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Pictures"); pan.message = "Pick an image for Photo Reader"
                NSApp.activate(ignoringOtherApps: true)
                return pan.runModal() == .OK ? ["path": pan.url?.path ?? ""] : ["path": ""] }
        case "openMain": DispatchQueue.main.async { (NSApplication.shared.delegate as? AppDelegate)?.showWindow() }; return ["ok": true]
        case "quitApp": DispatchQueue.main.async { NSApp.terminate(nil) }; return ["ok": true]
        case "permInfo":
            let n: (Int) -> String = { ["notDetermined", "restricted", "denied", "authorized/full", "writeOnly"][min($0, 4)] }
            return ["calendar": n(EKEventStore.authorizationStatus(for: .event).rawValue), "reminders": n(EKEventStore.authorizationStatus(for: .reminder).rawValue),
                    "speech": ["notDetermined", "denied", "restricted", "authorized"][SFSpeechRecognizer.authorizationStatus().rawValue],
                    "mic": ["notDetermined", "restricted", "denied", "authorized"][AVCaptureDevice.authorizationStatus(for: .audio).rawValue],
                    "pages": FileWrite.pagesPermission()]
        case "speechDown": mainSync { Speech.shared.input.holdDown(currentDraft: d["draft"] as? String ?? "") }; return ["ok": true]
        case "speechUp": mainSync { Speech.shared.input.holdUp() }; return ["ok": true]
        case "speechInfo": return mainSync { ["available": Speech.shared.input.available, "hint": Speech.shared.input.hint] }
        case "toolApplyId": return apply(pendingId: d["pendingId"] as? String ?? "")
        case "toolCancelId": cancel(pendingId: d["pendingId"] as? String ?? ""); return ["ok": true]
        default: return nil
        }
    }
}

import Combine
/// Hold-to-talk. Ported from Ask My Mac's SpeechInput (on-device only). Pushes text to every open page.
@MainActor
final class Speech {
    static let shared = Speech()
    let input = SpeechInput()
    var pages: [() -> WKWebView?] = []
    private var bag = Set<AnyCancellable>()
    init() {
        input.$dictation.combineLatest(input.$listening, input.$warning).receive(on: DispatchQueue.main).sink { [weak self] t, l, w in
            guard let self = self else { return }
            let j = (try? JSONSerialization.data(withJSONObject: ["text": t, "listening": l, "warning": w ?? ""])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            for p in self.pages { p()?.evaluateJavaScript("window.__speech && window.__speech(\(j))", completionHandler: nil) }
        }.store(in: &bag)
    }
}
