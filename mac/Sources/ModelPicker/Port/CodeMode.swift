import Foundation
import AppKit

/// Code mode (Nov 9). Hand-pick only, never part of Auto. She picks a project folder (a git repo), types a change in plain
/// English and presses Go. Under the hood it runs the local coding harness's "real projects" mode:
///   node harness/project.js --project P --ask A --model-url http://127.0.0.1:1337/v1 --model M --max-tokens 8192 [--check C]
/// The harness edits on a new harness/<time> branch (never main, never pushes), runs the check, keeps the change only if it
/// passes, and undoes everything if it fails or is stopped. Undo here = back to her branch + delete the harness branch.
///
/// Nov 9 (later): three jobs. "small" = project.js as above. "big" = harness/build.js --dir REPO --idea A on an existing git repo
/// (the model plans small steps; each step is one project.js run, on a harness/build-<time> branch). "new" = build.js on a new
/// empty folder ~/Projects/<name> (starter page + git). build.js exits 0 = all steps done, 1 = stopped partway (done steps kept,
/// rerun carries on), 130 = stopped by hand, 2 = refused. Its plan is saved in the harness's runs/plans/ (read here, never written).
/// THE one setting to switch models: CodeMode.defaultModel below (or the Model menu in the Code screen, saved as "codeModel").
/// Test-only env: SB_CODE_HARNESS (harness folder), SB_CODE_MODEL_URL (e.g. a fake model), SB_CODE_DIR (where the last result is kept).
enum CodeMode {
    static let defaultModel = "ornith-1.5-9b-mlx-4bit"   // Nov 9 race leader. If TwIL-8B wins: "twil-8b-mlx-4bit".
    static let models: [(id: String, name: String)] = [("ornith-1.5-9b-mlx-4bit", "Ornith 1.5 9B"), ("twil-8b-mlx-4bit", "TwIL-8B")]
    static let osaurusURL = "http://127.0.0.1:1337/v1"
    static let maxTokens = 8192
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var dir: String { env["SB_CODE_DIR"] ?? (SUPPORT + "/code") }
    static var modelURL: String { env["SB_CODE_MODEL_URL"] ?? osaurusURL }
    static func pref(_ k: String) -> Any? {
        let f = SUPPORT + "/ui-prefs.json"
        return ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: f)))) as? [String: Any])?[k]
    }
    static var projectsRoot: String { env["SB_CODE_PROJECTS"] ?? (home + "/Projects") }   // where New project makes its folder
    static var model: String { (pref("codeModel") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel }
    static var harness: String { env["SB_CODE_HARNESS"] ?? (pref("codeHarness") as? String) ?? (home + "/Projects/harness-game-kit") }
    static var node: String? {
        [home + "/.local/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func git(_ dir: String, _ args: [String]) -> (Int32, String) {
        let r = runCmd("/usr/bin/git", ["-C", dir] + args); return (r.0, r.1.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Read-only look at a folder: is it a git repo root, which branch, any uncommitted changes, a likely check command.
    static func inspect(_ p: String) -> [String: Any] {
        let path = (p as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return ["ok": false, "err": "That folder doesn't exist."] }
        var r: [String: Any] = ["ok": true, "path": path, "name": (path as NSString).lastPathComponent]
        let top = git(path, ["rev-parse", "--show-toplevel"])
        guard top.0 == 0 else { r["ok"] = false; r["err"] = "This folder isn't a git project, so changes couldn't be undone. Pick a folder that uses git."; return r }
        if URL(fileURLWithPath: top.1).standardized.path != URL(fileURLWithPath: path).standardized.path {
            r["ok"] = false; r["err"] = "Pick the project's top folder: \((top.1 as NSString).lastPathComponent)"; r["suggest"] = top.1; return r }
        if URL(fileURLWithPath: path).standardized.path == URL(fileURLWithPath: harness).standardized.path { r["ok"] = false; r["err"] = "That's the harness's own practice game. Pick a different project."; return r }
        r["branch"] = git(path, ["rev-parse", "--abbrev-ref", "HEAD"]).1
        let dirty = git(path, ["status", "--porcelain", "--untracked-files=no"]).1
        r["clean"] = dirty.isEmpty
        if !dirty.isEmpty { r["dirty"] = Array(dirty.split(separator: "\n").prefix(8).map(String.init)) }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: path + "/package.json")), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let s = o["scripts"] as? [String: Any], s["build"] != nil { r["check"] = "npm run build" }
        return r
    }

    /// New project: ~/Projects/<name>. Refuses a folder that already exists with files in it (unless resuming our own partway build).
    static func inspectNew(_ raw: String, resume: Bool = false) -> [String: Any] {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return ["ok": false, "err": "Type a name for the new project."] }
        let okChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        guard name.count <= 60, name.unicodeScalars.allSatisfy({ okChars.contains($0) }), !name.hasPrefix("."), !name.contains("..") else {
            return ["ok": false, "err": "Use letters, numbers, spaces, - or _ for the name (no slashes)."] }
        let path = projectsRoot + "/" + name
        var r: [String: Any] = ["ok": true, "path": path, "name": name, "display": path.replacingOccurrences(of: home, with: "~")]
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            let items = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { $0 != ".DS_Store" }
            if !isDir.boolValue || !items.isEmpty {
                if resume && isDir.boolValue && git(path, ["rev-parse", "--show-toplevel"]).0 == 0 { r["exists"] = true; return r }
                r["ok"] = false; r["err"] = "\(r["display"]!) already exists and isn't empty. Pick another name."; return r }
            r["exists"] = true
        }
        return r
    }

    static func config() -> [String: Any] {
        ["model": model, "defaultModel": defaultModel, "models": models.map { ["id": $0.id, "name": $0.name] }, "modelURL": modelURL,
         "harness": harness, "projectsRoot": projectsRoot.replacingOccurrences(of: home, with: "~"), "buildOK": FileManager.default.fileExists(atPath: harness + "/harness/build.js"), "harnessOK": FileManager.default.fileExists(atPath: harness + "/harness/project.js"), "node": node ?? "",
         "last": CodeRunner.lastSaved() ?? NSNull()]
    }

    @MainActor static func pickFolder() -> String? {
        let pan = NSOpenPanel(); pan.canChooseDirectories = true; pan.canChooseFiles = false; pan.allowsMultipleSelection = false
        pan.message = "Pick the project folder to change. Changes go on a separate branch; your main version is never touched."; pan.prompt = "Use this project"
        NSApp.activate(ignoringOtherApps: true)
        return pan.runModal() == .OK ? pan.url?.path : nil
    }
}

final class CodeJob {
    var state = "starting"   // starting, running, pass, fail, stopped, error, preview
    var lines: [String] = []
    var project = "", ask = "", model = "", check = "", startBranch = "", branch = "", commit = ""
    var files: [String] = [], diff = "", tries = 0, err = "", dry = false, undone = false
    var kind = "small"                 // small, big, new
    var steps: [[String: String]] = [] // the build plan: text + status (todo, done, failed, running)
    var step = 0, total = 0, doneN = 0, byHand = false, exitCode: Int32 = -1, splitting = false
    var t0 = Date(), secs = 0.0
    var proc: Process?
    var partial = ""
}

enum CodeRunner {
    static let lock = NSLock()
    static var job: CodeJob?
    static func with<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    static var running: Bool { with { job.map { ["starting", "running"].contains($0.state) } ?? false } }

    static func start(_ d: [String: Any]) -> [String: Any] {
        if running { return ["ok": false, "err": "A change is already running. Stop it first."] }
        let kind = ["small", "big", "new"].contains(d["kind"] as? String ?? "") ? d["kind"] as! String : "small"
        let resume = d["resume"] as? Bool ?? false
        let info = kind == "new" ? CodeMode.inspectNew(d["name"] as? String ?? "", resume: resume) : CodeMode.inspect(d["project"] as? String ?? "")
        guard info["ok"] as? Bool == true, let project = info["path"] as? String else { return ["ok": false, "err": info["err"] ?? "Pick a project folder first."] }
        let ask = (d["ask"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty else { return ["ok": false, "err": kind == "small" ? "Type the change you want first." : kind == "big" ? "Describe the big change first." : "Describe what to build first."] }
        let dry = kind == "small" && (d["dry"] as? Bool ?? false)
        if kind == "new" && info["exists"] as? Bool == true && !resume { /* an existing EMPTY folder is fine */ }
        if kind != "new" && !dry && info["clean"] as? Bool != true { return ["ok": false, "err": "This project has changes that aren't saved in git yet. Commit or stash them first, so nothing of yours gets mixed in."] }
        guard let node = CodeMode.node else { return ["ok": false, "err": "Node isn't installed, and the harness needs it."] }
        let kit = CodeMode.harness
        guard FileManager.default.fileExists(atPath: kit + "/harness/project.js") else { return ["ok": false, "err": "The coding harness isn't at \(kit)."] }
        if kind != "small" && !FileManager.default.fileExists(atPath: kit + "/harness/build.js") { return ["ok": false, "err": "This harness is too old for Big change / New project (no harness/build.js). Update it first."] }
        let j = CodeJob(); j.kind = kind; j.project = project; j.ask = ask; j.dry = dry; j.model = (d["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? CodeMode.model
        j.check = (d["check"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines); j.startBranch = kind == "new" ? "" : info["branch"] as? String ?? ""
        with { job = j }
        DispatchQueue.global().async { run(j, node: node, kit: kit) }
        return ["ok": true]
    }

    static func add(_ j: CodeJob, _ s: String) { with { j.lines.append(s); if j.lines.count > 3000 { j.lines.removeFirst(j.lines.count - 3000) } } }

    static func run(_ j: CodeJob, node: String, kit: String) {
        let url = CodeMode.modelURL
        // Live runs use Osaurus. It's only woken up here, when she presses Go (never for a preview, never with a test model URL).
        if !j.dry && url == CodeMode.osaurusURL, let e = ENGINE_DEFS.first(where: { $0.id == "osaurus" }) {
            if !engineUp(e) {
                add(j, "Starting Osaurus…")
                guard ensureEngineUp(e, seconds: 180) else { with { j.state = "error"; j.err = "Osaurus (the model app) didn't start." }; finish(j); return }
            }
        }
        var args: [String]
        if j.kind == "small" {
            args = [kit + "/harness/project.js", "--project", j.project, "--ask", j.ask]
            if j.dry { args.append("--show-context") } else { args += ["--model-url", url, "--model", j.model, "--max-tokens", "\(CodeMode.maxTokens)"] }
            if !j.check.isEmpty { args += ["--check", j.check] }
        } else {   // big change / new project: build.js plans small steps and runs project.js for each (it picks its own checks)
            args = [kit + "/harness/build.js", "--dir", j.project, "--idea", j.ask, "--model-url", url, "--model", j.model, "--max-tokens", "\(CodeMode.maxTokens)"]
            j.check = ""
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: node); p.arguments = args; p.currentDirectoryURL = URL(fileURLWithPath: kit)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (node as NSString).deletingLastPathComponent + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            with {
                let all = j.partial + s; var parts = all.components(separatedBy: "\n"); j.partial = parts.removeLast()
                j.lines += parts; if j.lines.count > 3000 { j.lines.removeFirst(j.lines.count - 3000) }
                if j.kind != "small" { for l in parts { parseBuild(j, l) } }
            }
        }
        add(j, j.dry ? "Preview: showing what the model would read. Nothing is changed." : j.kind == "small" ? "Model: \(j.model)\(j.check.isEmpty ? "" : " · check: \(j.check)")"
            : "\(j.kind == "new" ? "New project" : "Big change") · model: \(j.model) · folder: \(j.project)")
        do { try p.run() } catch { with { j.state = "error"; j.err = "Couldn't start the harness: \(error.localizedDescription)" }; finish(j); return }
        with { j.proc = p; if j.state == "starting" { j.state = "running" } }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        with { let s = j.partial + (String(data: rest, encoding: .utf8) ?? ""); j.partial = ""; let ls = s.components(separatedBy: "\n").filter { !$0.isEmpty }
            j.lines += ls; if j.kind != "small" { for l in ls { parseBuild(j, l) } } }
        let code = p.terminationStatus
        with { j.exitCode = code }
        if j.kind != "small" { finishBuild(j, code); finish(j); return }
        let out = with { j.lines }
        // Result: the harness prints "Log: runs/....json"; read it for the branch/commit. Fall back to the printed lines.
        var res: [String: Any] = [:]
        if let l = out.last(where: { $0.hasPrefix("Log: ") || $0.contains(" Log: ") }), let r = l.range(of: "Log: ") {
            let rel = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let d = try? Data(contentsOf: URL(fileURLWithPath: rel.hasPrefix("/") ? rel : kit + "/" + rel)), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { res = o }
        }
        with {
            j.tries = res["tries"] as? Int ?? (res["attempts"] as? [Any])?.count ?? 0
            if let sb = res["startBranch"] as? String, !sb.isEmpty { j.startBranch = sb }
            if j.dry { j.state = code == 0 ? "preview" : "error"; if code != 0 { j.err = out.last ?? "The preview failed." } }
            else if j.state == "stopped" || code == 130 { j.state = "stopped" }
            else if code == 0, res["pass"] as? Bool == true, let b = res["branch"] as? String, b.hasPrefix("harness/") {
                j.state = "pass"; j.branch = b; j.commit = res["commit"] as? String ?? "" }
            else if code == 0, let l = out.first(where: { $0.hasPrefix("PASS ") }), let r = l.range(of: " on harness/") {   // no log file: read the PASS line
                j.state = "pass"; j.branch = "harness/" + String(l[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            else if code == 2 { j.state = "error"; j.err = out.last(where: { $0.hasPrefix("project mode:") }).map { String($0.dropFirst(14)) } ?? (out.last ?? "The harness refused to run.") }
            else { j.state = "fail" }
        }
        if j.state == "pass" {
            let ref = j.commit.isEmpty ? j.branch : j.commit
            let names = CodeMode.git(j.project, ["show", "--name-only", "--format=", ref]).1
            let diff = CodeMode.git(j.project, ["show", "--format=", "--stat", "--patch", ref]).1
            with { j.files = names.split(separator: "\n").map(String.init).filter { !$0.isEmpty }; j.diff = String(diff.prefix(20000)) }
        }
        finish(j)
    }

    static func finish(_ j: CodeJob) {
        with { j.secs = Date().timeIntervalSince(j.t0); j.proc = nil }
        if !j.dry { save(j) }
    }

    static func snapshot(_ j: CodeJob, from: Int = 0) -> [String: Any] {
        with {
            let f = max(0, min(from, j.lines.count))
            return ["state": j.state, "lines": Array(j.lines[f...]), "next": j.lines.count, "project": j.project, "name": (j.project as NSString).lastPathComponent,
                    "ask": j.ask, "model": j.model, "check": j.check, "startBranch": j.startBranch, "branch": j.branch, "commit": j.commit, "files": j.files,
                    "diff": j.diff, "tries": j.tries, "err": j.err, "dry": j.dry, "undone": j.undone, "kind": j.kind, "steps": j.steps, "step": j.step,
                    "total": j.total, "doneN": j.doneN, "exitCode": Int(j.exitCode), "byHand": j.byHand, "splitting": j.splitting,
                    "secs": ["starting", "running"].contains(j.state) ? Date().timeIntervalSince(j.t0) : j.secs]
        }
    }
    static func status(_ from: Int) -> [String: Any] {
        guard let j = with({ job }) else { return ["state": "none"] }
        if j.kind != "small" && running { readPlan(j) }
        return snapshot(j, from: from)
    }

    // ---- Big change / New project (harness/build.js) ----
    /// build.js saves its plan as runs/plans/<folder>-<last 10 of base64url(path)>.json in the harness folder. Read only.
    static func planFile(_ root: String) -> String {
        let b = Data(root.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return CodeMode.harness + "/runs/plans/" + (root as NSString).lastPathComponent + "-" + String(b.suffix(10)) + ".json"
    }
    static func readPlan(_ j: CodeJob) {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: planFile(j.project))), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              o["idea"] as? String == j.ask, let st = o["steps"] as? [[String: Any]] else { return }
        with {
            j.steps = st.enumerated().map { i, s in
                let raw = s["status"] as? String ?? "todo"
                return ["text": s["text"] as? String ?? "", "status": raw == "todo" && i + 1 == j.step && ["starting", "running"].contains(j.state) ? "running" : raw] }
            j.total = j.steps.count; j.doneN = j.steps.filter { $0["status"] == "done" }.count
            if j.kind == "big", let b = o["branch"] as? String, b.hasPrefix("harness/") { j.branch = b; if let base = o["base"] as? String { j.startBranch = base } }
        }
    }
    /// Called with the lock held, once per printed line.
    static func parseBuild(_ j: CodeJob, _ l: String) {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t == "Plan:" { j.steps = []; return }
        if let m = t.range(of: #"^\d+\. \[( |x)\] "#, options: .regularExpression), j.step == 0 {
            j.steps.append(["text": String(t[m.upperBound...]), "status": t[m].contains("[x]") ? "done" : "todo"]); j.total = j.steps.count
            j.doneN = j.steps.filter { $0["status"] == "done" }.count; return }
        if t.hasPrefix("=== Step "), let r = t.range(of: #"^=== Step (\d+) of (\d+): "#, options: .regularExpression) {
            let nums = t[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count == 2 {
                // a split step makes the plan longer; the plan file (read on each status) fills in the new step texts
                if nums[1] == j.steps.count { for i in j.steps.indices where j.steps[i]["status"] == "running" { j.steps[i]["status"] = "done" }
                    if nums[0] - 1 < j.steps.count { j.steps[nums[0] - 1]["status"] = "running" } }
                j.step = nums[0]; j.total = nums[1]; j.splitting = false
                j.doneN = j.steps.filter { $0["status"] == "done" }.count
            }
            return }
        if t.contains("was too hard in one go") { j.splitting = true; return }
        if let r = t.range(of: #"^(\d+) of (\d+) steps done"#, options: .regularExpression) {
            let nums = t[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count == 2 { j.doneN = nums[0]; j.total = nums[1] }
            if let b = t.range(of: #"\(branch [^)]+\)"#, options: .regularExpression) {
                let br = String(t[b].dropFirst(8).dropLast()); if j.kind == "big" && br.hasPrefix("harness/") { j.branch = br } }
            return }
        if t.hasPrefix("Your "), let r = t.range(of: " branch is unchanged") { j.startBranch = String(t[t.index(t.startIndex, offsetBy: 5)..<r.lowerBound]) }
    }
    static func finishBuild(_ j: CodeJob, _ code: Int32) {
        readPlan(j)   // the plan file is renamed when all steps are done, so this may keep the parsed list
        let out = with { j.lines }
        with {
            if code == 0 { j.state = "done"; for i in j.steps.indices { j.steps[i]["status"] = "done" }; j.doneN = j.steps.count; j.total = j.steps.count }
            else if j.byHand || code == 130 { j.state = "stopped" }
            else if code == 2 { j.state = "error"; j.err = out.last(where: { $0.hasPrefix("build:") || $0.hasPrefix("project mode:") }).map { $0.replacingOccurrences(of: "build: ", with: "") } ?? (out.last ?? "The harness refused to run.") }
            else { j.state = "partway" }
            for i in j.steps.indices where j.steps[i]["status"] == "running" { j.steps[i]["status"] = j.state == "done" ? "done" : "todo" }
        }
        // what changed: big = base..branch; new = everything since the starter page commit
        var from = "", to = "HEAD"
        if j.kind == "big", !j.startBranch.isEmpty, !j.branch.isEmpty { from = j.startBranch; to = j.branch }
        if j.kind == "new" { from = CodeMode.git(j.project, ["rev-list", "--max-parents=0", "HEAD"]).1.split(separator: "\n").first.map(String.init) ?? "" }
        if !from.isEmpty, j.state != "error" {
            let names = CodeMode.git(j.project, ["diff", "--name-only", from, to]).1
            let diff = CodeMode.git(j.project, ["diff", "--stat", "--patch", from, to]).1
            let commits = CodeMode.git(j.project, ["rev-list", "--count", from + ".." + to]).1
            with { j.files = names.split(separator: "\n").map(String.init).filter { !$0.isEmpty }; j.diff = String(diff.prefix(30000)); j.tries = Int(commits) ?? 0 }
        }
    }

    /// Stop = Ctrl-C for the harness: it undoes its edits, goes back to her branch and deletes its half-done branch.
    static func stop() -> [String: Any] {
        guard let j = with({ job }), let p = with({ j.proc }), p.isRunning else { return ["ok": false] }
        with { j.state = "stopped"; j.byHand = true }; add(j, j.kind == "small" ? "Stopping… (undoing any half-done edit)" : "Stopping… (the step in progress is undone; finished steps are kept)")
        p.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { if p.isRunning { p.terminate() } }   // a running check finishes first; never hang
        return ["ok": true]
    }

    /// Undo a kept change: back to the branch she was on, then delete the harness/... branch. Refuses anything else.
    static func undo(_ d: [String: Any]) -> [String: Any] {
        let last = lastSaved() ?? [:]
        let project = d["project"] as? String ?? last["project"] as? String ?? ""
        let branch = d["branch"] as? String ?? last["branch"] as? String ?? ""
        let back = d["startBranch"] as? String ?? last["startBranch"] as? String ?? ""
        guard branch.hasPrefix("harness/"), !project.isEmpty, !back.isEmpty, !back.hasPrefix("harness/") else { return ["ok": false, "err": "Nothing to undo."] }
        if running { return ["ok": false, "err": "Wait for the current run to finish first."] }
        guard CodeMode.git(project, ["rev-parse", "--verify", "--quiet", "refs/heads/" + branch]).0 == 0 else {
            markUndone(project, branch); return ["ok": true, "already": true, "text": "Already undone: that branch is gone."] }
        let cur = CodeMode.git(project, ["rev-parse", "--abbrev-ref", "HEAD"]).1
        if cur == branch {
            if !CodeMode.git(project, ["status", "--porcelain", "--untracked-files=no"]).1.isEmpty {
                return ["ok": false, "err": "There are new unsaved edits on \(branch). Commit or discard them first, then Undo."] }
            let co = CodeMode.git(project, ["checkout", "-q", back])
            if co.0 != 0 { return ["ok": false, "err": "Couldn't switch back to \(back): \(co.1)"] }
        }
        let del = CodeMode.git(project, ["branch", "-D", branch])
        if del.0 != 0 { return ["ok": false, "err": "Couldn't delete \(branch): \(del.1)"] }
        markUndone(project, branch)
        return ["ok": true, "text": "Undone. Back on \(back); the change on \(branch) is gone."]
    }

    static func markUndone(_ project: String, _ branch: String) {
        with { if let j = job, j.project == project, j.branch == branch { j.undone = true } }
        if var l = lastSaved(), l["branch"] as? String == branch { l["undone"] = true; write(l) }
    }
    static func save(_ j: CodeJob) {
        var s = snapshot(j); s["lines"] = Array((s["lines"] as? [String] ?? []).suffix(200)); s["at"] = Date().timeIntervalSince1970; write(s)
    }
    static func write(_ o: [String: Any]) {
        try? FileManager.default.createDirectory(atPath: CodeMode.dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: CodeMode.dir + "/last.json"), options: .atomic) }
    }
    static func lastSaved() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CodeMode.dir + "/last.json")))) as? [String: Any]
    }
    static func stopForQuit() { if running { _ = stop(); for _ in 0..<40 where running { usleep(250_000) } } }
}
