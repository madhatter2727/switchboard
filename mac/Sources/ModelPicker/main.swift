import Cocoa
import ServiceManagement
import WebKit
import Speech

final class Bridge: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler, URLSessionDataDelegate {
    weak var web: WKWebView?
    var tasks: [Int: URLSessionDataTask] = [:]
    var bufs: [Int: Data] = [:]
    var streamURL: [Int: URL] = [:]   // stream id -> engine URL (for the 15-minute idle stop)
    var session: URLSession!
    var netTasks: [String: URLSessionDataTask] = [:]   // agent requests the Stop button can cancel
    override init() { super.init(); session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil) }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let d = m.body as? [String: Any] ?? [:]
        if m.name == "net" {
            guard let us = d["url"] as? String, let url = localOK(us) else { replyHandler(["error": "blocked", "status": 0, "body": ""], nil); return }
            var r = URLRequest(url: url); r.httpMethod = (d["method"] as? String) ?? "GET"; r.timeoutInterval = (d["timeout"] as? Double) ?? 5
            if let b = d["body"] as? String { r.httpBody = b.data(using: .utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let act = r.httpMethod == "POST" ? UUID().uuidString : nil
            if let a = act { Owned.noteRequest(url: url, body: r.httpBody); Owned.noteActivity(url: url, token: a, begin: true) }
            let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = r.timeoutInterval
            let rid = d["rid"] as? String
            let t = URLSession(configuration: cfg).dataTask(with: r) { data, resp, err in
                if let rid = rid { DispatchQueue.main.async { self.netTasks[rid] = nil } }
                if let a = act { Owned.noteActivity(url: url, token: a, begin: false) }
                if let e = err as NSError? { replyHandler(["error": e.code == NSURLErrorCancelled ? "cancelled" : "unreachable", "status": 0, "body": ""], nil); return }
                replyHandler(["status": (resp as? HTTPURLResponse)?.statusCode ?? 0, "body": String(data: data ?? Data(), encoding: .utf8) ?? ""], nil)
            }
            if let rid = rid { netTasks[rid] = t }
            t.resume()
        } else if m.name == "act" {
            let op = d["op"] as? String ?? "", eng = d["engine"] as? String ?? ""
            if op == "netCancel" { let rid = d["rid"] as? String ?? ""; netTasks[rid]?.cancel(); replyHandler(["ok": netTasks[rid] != nil], nil); return }
            DispatchQueue.global().async { replyHandler(self.act(op, eng, d), nil) }
        } else { replyHandler(nil, "unknown") }
    }

    func act(_ op: String, _ eng: String, _ d: [String: Any]) -> [String: Any] {
        ensureDirs()
        let fm = FileManager.default
        switch op {
        case "list":
            let (_, _) = (0, 0)
            let ids = modelIds(ENGINE_DEFS.first { $0.id == eng } ?? ENGINE_DEFS[0])
            return ["lines": ids]
        case "saveChat":
            if let id = d["id"] as? String, let t = d["json"] as? String, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                try? t.write(toFile: CHATS + "/" + id + ".json", atomically: true, encoding: .utf8) }
            return ["ok": true]
        case "listChats":
            let files = ((try? fm.contentsOfDirectory(atPath: CHATS)) ?? []).filter { $0.hasSuffix(".json") }
            return ["chats": files.compactMap { try? String(contentsOfFile: CHATS + "/" + $0, encoding: .utf8) }]
        case "trashChat":
            if let id = d["id"] as? String, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                try? fm.trashItem(at: URL(fileURLWithPath: CHATS + "/" + id + ".json"), resultingItemURL: nil) }
            return ["ok": true]
        case "trashAllChats":
            // Same as the per-chat Delete, for every chat: each file goes to the macOS Trash (nothing is permanently deleted).
            let files = ((try? fm.contentsOfDirectory(atPath: CHATS)) ?? []).filter { $0.hasSuffix(".json") }
            var moved = 0, failed = 0
            for f in files { do { try fm.trashItem(at: URL(fileURLWithPath: CHATS + "/" + f), resultingItemURL: nil); moved += 1 } catch { failed += 1 } }
            return ["ok": failed == 0, "moved": moved, "failed": failed]
        case "toolRun": return AgentTools.run(d["name"] as? String ?? "", d["args"] as? String ?? "{}")
        case "toolApply" where (d["pendingId"] as? String ?? "") != "": return PortTools.apply(pendingId: d["pendingId"] as! String)
        case "toolApply": return ["text": AgentTools.apply(d["name"] as? String ?? "", d["args"] as? String ?? "{}")]
        case "prefsGet", "prefsSet":   // small window settings (which model groups are collapsed), kept between launches
            let f = SUPPORT + "/ui-prefs.json"; let key = d["key"] as? String ?? ""
            var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: f)))) as? [String: Any] ?? [:]
            if op == "prefsGet" { return ["value": all[key] ?? NSNull()] }
            all[key] = d["value"] ?? NSNull()
            if let j = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]) { try? j.write(to: URL(fileURLWithPath: f), options: .atomic) }
            return ["ok": true]
        case "state":
            if let t = d["json"] as? String { try? t.write(toFile: STATE, atomically: true, encoding: .utf8) }
            return ["ok": true]
        case "copy":   // puts plain text on the Mac clipboard (the Copy buttons use this; WKWebView's own clipboard can be blocked)
            if let t = d["text"] as? String, t.count < 2_000_000 { DispatchQueue.main.sync { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }; return ["ok": true, "copied": true] }
            return ["ok": false]
        case "mem":   // read-only: Mac memory in use vs total, same maths as Activity Monitor's "Memory Used" (app + wired + compressed). Changes nothing.
            var vm = vm_statistics64(); var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt) } }
            var ps: vm_size_t = 0; host_page_size(mach_host_self(), &ps)
            guard kr == KERN_SUCCESS else { return ["ok": false] }
            let app = UInt64(vm.internal_page_count) > UInt64(vm.purgeable_count) ? UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count) : 0
            let used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * UInt64(ps)
            return ["ok": true, "used": Int(used), "total": Int(ProcessInfo.processInfo.physicalMemory)]
        default: if let r = PortTools.handle(op, d) { return r }; return engineAct(op, eng, d)
        }
    }

    // ---- streaming chat ----
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let d = m.body as? [String: Any] ?? [:]
        guard let id = d["id"] as? Int else { return }
        if (d["cmd"] as? String) == "cancel" { tasks[id]?.cancel(); return }
        guard let us = d["url"] as? String, let url = localOK(us) else { emit(id, "error", "blocked"); return }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 600
        r.httpBody = (d["body"] as? String)?.data(using: .utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Owned.noteRequest(url: url, body: r.httpBody); Owned.noteActivity(url: url, token: "s\(id)", begin: true); streamURL[id] = url
        let t = session.dataTask(with: r); tasks[id] = t; bufs[id] = Data(); t.taskDescription = "\(id)"; t.resume()
    }
    func idOf(_ t: URLSessionTask) -> Int { Int(t.taskDescription ?? "") ?? -1 }
    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive resp: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { emit(idOf(t), "error", "The engine answered with error \(h.statusCode).") }
        completionHandler(.allow)
    }
    func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive data: Data) {
        let id = idOf(t); var b = bufs[id] ?? Data(); b.append(data)
        while let nl = b.firstIndex(of: 10) {
            let line = String(data: b[b.startIndex..<nl], encoding: .utf8) ?? ""
            b = Data(b[(nl + 1)...]); emit(id, "line", line)
        }
        bufs[id] = b
    }
    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
        let id = idOf(t)
        if let rest = bufs[id], !rest.isEmpty, let l = String(data: rest, encoding: .utf8) { emit(id, "line", l) }
        if let e = e as NSError?, e.code != NSURLErrorCancelled { emit(id, "error", "Could not reach the engine.") }
        emit(id, "done", ""); tasks[id] = nil; bufs[id] = nil
        if let u = streamURL.removeValue(forKey: id) { Owned.noteActivity(url: u, token: "s\(id)", begin: false) }
    }
    func emit(_ id: Int, _ type: String, _ text: String) {
        guard let j = try? JSONSerialization.data(withJSONObject: ["id": id, "type": type, "text": text]), let s = String(data: j, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.web?.evaluateJavaScript("window.__stream && window.__stream(\(s))", completionHandler: nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var web: WKWebView!
    let bridge = Bridge()
    func applicationDidFinishLaunching(_ n: Notification) {
        let cfg = WKWebViewConfiguration(); let ucc = WKUserContentController()
        ucc.addScriptMessageHandler(bridge, contentWorld: .page, name: "net")
        ucc.addScriptMessageHandler(bridge, contentWorld: .page, name: "act")
        ucc.add(bridge, name: "stream"); cfg.userContentController = ucc; mainSync { Speech.shared.pages = [{ [weak self] in self?.web }] }
        web = WKWebView(frame: .zero, configuration: cfg); bridge.web = web
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Switchboard"; window.contentView = web; window.center(); window.setFrameAutosaveName("ModelPicker"); window.delegate = self; window.isReleasedWhenClosed = false; setUpStatusItem()
        // Login item follows the app if it moves or is renamed (Model Picker.app -> Switchboard.app, Oct 21).
        let regKey = "loginItemPath"
        if UserDefaults.standard.string(forKey: regKey) != Bundle.main.bundlePath { try? SMAppService.mainApp.unregister(); UserDefaults.standard.set(Bundle.main.bundlePath, forKey: regKey) }
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let res = Bundle.main.resourceURL?.appendingPathComponent("web") { web.loadFileURL(res.appendingPathComponent("index.html"), allowingReadAccessTo: res) }
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let sub = NSMenu(); sub.addItem(withTitle: "About Switchboard", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); sub.addItem(.separator()); sub.addItem(withTitle: "Hide Switchboard", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"); sub.addItem(withTitle: "Quit Switchboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = sub
        let editItem = NSMenuItem(); menu.addItem(editItem); let em = NSMenu(title: "Edit")
        em.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"); em.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        em.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"); em.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        em.addItem(.separator()); let ue = NSMenuItem(title: "Undo Last Action", action: #selector(undoLastFromMenu), keyEquivalent: ""); ue.target = self; em.insertItem(ue, at: 0)
        editItem.submenu = em; NSApp.mainMenu = menu
        if CommandLine.arguments.contains("--show-popover") { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.quickChat() } }
        if let i = CommandLine.arguments.firstIndex(of: "--mini-send"), CommandLine.arguments.count > i + 1 {
            let t = CommandLine.arguments[i + 1].replacingOccurrences(of: "'", with: "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { self.miniWeb?.evaluateJavaScript("send('\(t)')", completionHandler: nil) }
        }
        if CommandLine.arguments.contains("--selftest") { selftest() }
    }
    /// `open -n app --args --selftest ENGINE MODEL` : drives the real page, writes selftest.json
    func selftest() {
        let a = CommandLine.arguments; let i = a.firstIndex(of: "--selftest")!
        let mode = a.count > i + 1 ? a[i + 1] : "chat", eng = a.count > i + 2 ? a[i + 2] : "", model = a.count > i + 3 ? a[i + 3] : ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            self.web.callAsyncJavaScript("return await window.__selftest('\(mode)','\(eng)','\(model)')", arguments: [:], in: nil, in: .page) { r in
                var out = ""
                switch r { case .success(let v): out = "\(v ?? "null")"; case .failure(let e): out = "ERR \(e)" }
                try? out.write(toFile: NSHomeDirectory() + "/Projects/model-picker/selftest.json", atomically: true, encoding: .utf8)
                let snap = WKSnapshotConfiguration()
                self.web.takeSnapshot(with: snap) { img, _ in if let img = img, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/Projects/model-picker/selftest.png")) } }
            }
        }
    }
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var miniWeb: WKWebView?
    let miniBridge = Bridge()
    func makeMini() {
        let cfg = WKWebViewConfiguration(); let ucc = WKUserContentController()
        ucc.addScriptMessageHandler(miniBridge, contentWorld: .page, name: "net")
        ucc.addScriptMessageHandler(miniBridge, contentWorld: .page, name: "act")
        ucc.add(miniBridge, name: "stream")
        ucc.addUserScript(WKUserScript(source: "window.__MINI=true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 560), configuration: cfg); miniBridge.web = w; miniWeb = w
        if let res = Bundle.main.resourceURL?.appendingPathComponent("web") { w.loadFileURL(res.appendingPathComponent("index.html"), allowingReadAccessTo: res) }
        let vc = NSViewController(); vc.view = w
        let po = NSPopover(); po.contentSize = NSSize(width: 400, height: 560); po.behavior = .transient; po.contentViewController = vc; popover = po
        mainSync { Speech.shared.pages = [{ [weak self] in self?.web }, { [weak self] in self?.miniWeb }] }
    }
    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || (ev?.modifierFlags.contains(.control) ?? false) {
            statusItem?.menu = statusMenu; statusItem?.button?.performClick(nil); statusItem?.menu = nil; return }
        if popover == nil { makeMini() }
        if popover!.isShown { popover!.performClose(nil) } else {
            popover!.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true)
            miniWeb?.evaluateJavaScript("window.__miniOpen && window.__miniOpen()", completionHandler: nil) }
    }
    var statusMenu: NSMenu?
    var undoStatusItem: NSMenuItem?
    var undoEditItem: NSMenuItem?
    func refreshUndoMenu() {}
    @objc func quickChat() { if let b = statusItem?.button { statusClicked(b) } }
    @objc func openSettings() { showWindow(); web.evaluateJavaScript("window.__openSettings && window.__openSettings()", completionHandler: nil) }
    @objc func undoLastFromMenu() {
        DispatchQueue.global().async {
            let r = PortTools.handle("undoLast", [:]) ?? [:]
            let msg = (r["text"] as? String ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: " ")
            DispatchQueue.main.async { self.web.evaluateJavaScript("window.__undoDone && window.__undoDone('\(msg)')", completionHandler: nil) }
        }
    }
    func validateMenuItem(_ i: NSMenuItem) -> Bool { if i.action == #selector(undoLastFromMenu) { return mainSync { UndoLog.hasEntries } }; return true }
    func setUpStatusItem() {
        // A crowded menu bar puts the newest icon furthest left, where the MacBook notch hides it.
        // Ask for a spot near the clock instead (Tara can still ⌘-drag it anywhere; macOS remembers).
        let posKey = "NSStatusItem Preferred Position ModelPickerStatus"
        if UserDefaults.standard.object(forKey: posKey) == nil { UserDefaults.standard.set(520.0, forKey: posKey) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "ModelPickerStatus"; item.behavior = []
        if let b = item.button { b.image = NSImage(systemSymbolName: "rectangle.3.group.bubble", accessibilityDescription: "Switchboard"); b.toolTip = "Switchboard" }
        let m = NSMenu()
        let o = NSMenuItem(title: "Open Switchboard", action: #selector(showWindow), keyEquivalent: ""); o.target = self
        let q = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let u = NSMenuItem(title: "Undo Last Action", action: #selector(undoLastFromMenu), keyEquivalent: ""); u.target = self; undoStatusItem = u
        let qc = NSMenuItem(title: "Quick Chat", action: #selector(quickChat), keyEquivalent: ""); qc.target = self
        let st = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ""); st.target = self
        m.addItem(qc); m.addItem(o); m.addItem(u); m.addItem(st); m.addItem(.separator()); m.addItem(q); statusMenu = m; statusItem = item
        item.button?.target = self; item.button?.action = #selector(statusClicked(_:)); item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    @objc func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }   // closing the window keeps the menu bar item (and its models)
    /// Quit (Cmd+Q, menu Quit, menu bar Quit): stop the local models Switchboard started, unless Ask My Mac is
    /// still open (it shares them through 7777). Crash / force-quit is covered by the 7777 helper's watcher.
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        if CommandLine.arguments.contains("--selftest") { return .terminateNow }
        let others = otherClientsOpen(excludingSelf: true)
        launchLog("Switchboard quitting; Ask My Mac or another Switchboard open: \(others)")
        if others || Owned.isEmpty { return .terminateNow }
        window?.orderOut(nil)
        DispatchQueue.global().async {
            Owned.stopAll(reason: "Switchboard quit")
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.reply(toApplicationShouldTerminate: true) }   // never hang a quit
        return .terminateLater
    }
}
/// Is a Switchboard window app (other than this process) or Ask My Mac running?
/// Uses the process list, not AppKit: the 7777 helper must never register with macOS as an app
/// (when it did, Finder/Spotlight "opened" Switchboard by just activating the invisible helper).
func otherClientsOpen(excludingSelf: Bool) -> Bool { switchboardWindowOpen() || askMyMacOpen() }
func switchboardWindowOpen() -> Bool {
    let out = runCmd("/usr/bin/pgrep", ["-fl", "Switchboard.app/Contents/MacOS/Switchboard"]).1
    let me = "\(getpid())"
    return out.split(separator: "\n").contains { l in
        let f = l.split(separator: " "); guard let pid = f.first, String(pid) != me else { return false }
        return !l.contains(" --proxy") && !l.contains(" --tool ") && !l.contains(" --preroute") && !l.contains(" --undo-last") && !l.contains(" --transcribe") }
}
func askMyMacOpen() -> Bool { runCmd("/usr/bin/pgrep", ["-x", "AskMyMac"]).0 == 0 }

/// Runs inside the 7777 helper. Every 5 s: if neither Switchboard's window app nor Ask My Mac is running
/// (closed, crashed or force-quit) for 10 s, stop what Switchboard started. Also stops Ask My Mac's own
/// engines (Spark / Bonsai 27B jobs) once Ask My Mac has been gone 10 s, in case it crashed.
final class Watcher {
    var goneSince: Date?, ammGoneSince: Date?
    let proxy: Proxy
    init(_ p: Proxy) { proxy = p }
    let q = DispatchQueue(label: "watcher"); var timer: DispatchSourceTimer?
    func start() { let t = DispatchSource.makeTimerSource(queue: q); t.schedule(deadline: .now() + 5, repeating: 5); t.setEventHandler { [weak self] in self?.tick() }; t.resume(); timer = t }
    var ticks = 0
    func tick() {
        ticks += 1
        if ticks % 6 == 0 { DispatchQueue.global().async { Owned.stopIdle() } }   // every 30 s: Switchboard's own models idle 15 min stop
        let sb = switchboardWindowOpen(), amm = askMyMacOpen()
        if amm { ammGoneSince = nil } else {
            if ammGoneSince == nil { ammGoneSince = Date() }
            if Date().timeIntervalSince(ammGoneSince!) >= 10 {
                DispatchQueue.global().async { for l in ["com.tara.askmymac.spark", "com.tara.askmymac.bonsai"] where runCmd("/bin/launchctl", ["list", l]).0 == 0 {
                    _ = runCmd("/bin/launchctl", ["remove", l]); launchLog("owned: stopped \(l) because Ask My Mac is not running") } }
            }
        }
        if sb || amm { goneSince = nil; return }
        if goneSince == nil { goneSince = Date() }
        guard Date().timeIntervalSince(goneSince!) >= 10, !Owned.isEmpty else { return }
        let keep = proxy.busyEngines(otherAppsWithin: 600)
        DispatchQueue.global().async { Owned.stopAll(reason: "neither Switchboard nor Ask My Mac is open", keep: keep) }
    }
}
// Test harness (benchmark): `ModelPicker --tool NAME 'ARGS_JSON' [--apply]` runs one agent tool and prints JSON.
if let i = CommandLine.arguments.firstIndex(of: "--tool"), CommandLine.arguments.count > i + 2 {
    let n = CommandLine.arguments[i + 1], a = CommandLine.arguments[i + 2]
    DispatchQueue.global().async {
        var r = AgentTools.run(n, a)
        if CommandLine.arguments.contains("--apply"), r["pending"] as? Bool == true, let pid = r["pendingId"] as? String { let ap = PortTools.apply(pendingId: pid); r = ["text": ap["text"] ?? "", "applied": true, "ok": ap["ok"] ?? false, "undoId": ap["undoId"] ?? ""] }
        if let d = try? JSONSerialization.data(withJSONObject: r), let t = String(data: d, encoding: .utf8) { print(t) }
        fflush(stdout); exit(0)
    }
    RunLoop.main.run()
}
// Dry run (no request sent, nothing started): which model would the 7777 helper's "auto" pick for this request body?
// `Switchboard --route-auto 'BODY_JSON' ['INSTALLED_JSON']`. INSTALLED_JSON (optional) fakes the installed lists, e.g. {"lfm3vl":["lfm3-vl-2b"]}.
if let i = CommandLine.arguments.firstIndex(of: "--route-auto"), CommandLine.arguments.count > i + 1 {
    let a = CommandLine.arguments
    let body = (try? JSONSerialization.jsonObject(with: Data(a[i + 1].utf8))) as? [String: Any] ?? [:]
    let fake = a.count > i + 2 ? (try? JSONSerialization.jsonObject(with: Data(a[i + 2].utf8))) as? [String: [String]] : nil
    let r = autoRouteForProxy(body, ids: { id in fake.map { $0[id] ?? [] } ?? (ENGINE_DEFS.first { $0.id == id }.map(modelIds) ?? []) })
    if let d = try? JSONSerialization.data(withJSONObject: ["engine": r.eng, "model": r.model, "why": r.why]), let t = String(data: d, encoding: .utf8) { print(t) }
    exit(0)
}
// Dry run: which of Switchboard's own engines the idle stop would stop now (or N seconds from now). Stops nothing.
if let i = CommandLine.arguments.firstIndex(of: "--idle-check") {
    let off = CommandLine.arguments.count > i + 1 ? Double(CommandLine.arguments[i + 1]) ?? 0 : 0
    print(Owned.stopIdle(dryRun: true, atOffset: off)); exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--undo-last") {
    _ = i; DispatchQueue.global().async { let r = PortTools.handle("undoLast", [:]) ?? [:]; print(r["text"] ?? ""); fflush(stdout); exit(0) }; RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--preroute"), CommandLine.arguments.count > i + 1 {
    let t = CommandLine.arguments[i + 1]
    DispatchQueue.global().async {
        var r = PortTools.handle("preroute", ["text": t]) ?? [:]
        if CommandLine.arguments.contains("--apply"), r["pending"] as? Bool == true, let pid = r["pendingId"] as? String { r["applied"] = PortTools.apply(pendingId: pid) }
        if let d = try? JSONSerialization.data(withJSONObject: r), let s = String(data: d, encoding: .utf8) { print(s) }
        fflush(stdout); exit(0) }
    RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--transcribe-live"), CommandLine.arguments.count > i + 1 {
    // Voice self-test: feeds an audio file through the same path the mic uses, in real time. No model, no network.
    let f = CommandLine.arguments[i + 1]
    Task {
        var out = "SpeechTranscriber not available on this macOS"
        if #available(macOS 26.0, *) { let e = CommandLine.arguments.firstIndex(of: "--end-at").flatMap { Double(CommandLine.arguments[$0 + 1]) }; out = await LiveTranscriber.liveFile(f, endAt: e) }
        print(out); fflush(stdout); exit(0)
    }
    RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), CommandLine.arguments.count > i + 1 {
    let f = CommandLine.arguments[i + 1]
    Task {
        var out = "SpeechTranscriber not available on this macOS"
        if #available(macOS 26.0, *) { out = "available=\(SpeechTranscriber.isAvailable) text=" + (await LiveTranscriber.transcribeFile(f)) }
        try? out.write(toFile: NSHomeDirectory() + "/Projects/model-picker/transcribe.txt", atomically: true, encoding: .utf8)
        print(out); fflush(stdout); exit(0)
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--proxy") {
    // No NSApplication here on purpose (see switchboardWindowOpen).
    let px = Proxy(); px.start(); let w = Watcher(px); w.start(); dispatchMain()
} else {
    let app = NSApplication.shared
    let del = AppDelegate(); app.delegate = del; app.setActivationPolicy(.regular); app.run()
}
