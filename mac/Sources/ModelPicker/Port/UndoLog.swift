import Foundation

struct UndoOutcome: Equatable {
    var ok: Bool
    var message: String
}

struct UndoStep: Codable, Equatable {
    var op: String
    var from: String?
    var to: String?
    var path: String?
}

struct UndoEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: String
    var summary: String
    var steps: [UndoStep]
}

/// Reverse ops for approved changes. The app support folder is the one Library path we may write.
enum UndoLog {
    private static let cap = 40

    static var hasEntries: Bool { !load().isEmpty }

    static func lastID() -> UUID? { load().last?.id }

    static func jsonString(id: UUID) -> String? {
        guard let entry = load().first(where: { $0.id == id }) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entry), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    @discardableResult
    static func record(kind: String, summary: String, steps: [UndoStep]) -> UUID? {
        guard !steps.isEmpty else { return nil }
        var entries = load()
        let entry = UndoEntry(id: UUID(), kind: kind, summary: summary, steps: steps)
        entries.append(entry)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
        guard save(entries) else { return nil }
        return entry.id
    }

    static func undoLast() -> UndoOutcome {
        guard let id = lastID() else {
            return UndoOutcome(ok: false, message: "Nothing to undo.")
        }
        return undo(id: id)
    }

    static func undo(id: UUID) -> UndoOutcome {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return UndoOutcome(ok: false, message: "That action is not in the undo log.")
        }
        let entry = entries[index]
        let outcome = perform(entry.steps)
        if outcome.error == nil {
            entries.remove(at: index)
        } else {
            var updated = entry
            updated.steps = outcome.remaining
            entries[index] = updated
        }
        if !save(entries) {
            let detail = outcome.error ?? "Undid \(entry.summary)."
            return UndoOutcome(ok: false, message: "\(detail) The undo log could not be saved.")
        }
        if let error = outcome.error {
            return UndoOutcome(ok: false, message: error)
        }
        return UndoOutcome(ok: true, message: "Undid \(entry.summary).")
    }

    /// Runs every step, stopping at the first failure. `remaining` still includes the failed step.
    static func perform(_ steps: [UndoStep]) -> (remaining: [UndoStep], error: String?) {
        var index = 0
        while index < steps.count {
            if let error = apply(steps[index]) {
                return (Array(steps[index...]), error)
            }
            index += 1
        }
        return ([], nil)
    }

    private static func apply(_ step: UndoStep) -> String? {
        switch step.op {
        case "move":
            guard let from = step.from, let to = step.to else { return "The undo record is missing a path." }
            return moveBack(from: from, to: to)
        case "trash":
            guard let path = step.path else { return "The undo record is missing a path." }
            return trashCopy(path)
        case "restoreFile":
            guard let from = step.from, let to = step.to else { return "The undo record is missing a path." }
            return FileWrite.restore(from: from, to: to)
        case "removeEmptyFolder":
            guard let path = step.path else { return "The undo record is missing a path." }
            return removeEmptyFolder(path)
        default:
            return "Unknown undo step \(step.op)."
        }
    }

    private static func moveBack(from rawFrom: String, to rawTo: String) -> String? {
        guard let to = homePath(rawTo) else { return "Refused to undo into \(rawTo)." }
        guard let from = sourcePath(rawFrom) else { return "Refused to undo from \(rawFrom)." }
        let fromExists = FileManager.default.fileExists(atPath: from)
        let toExists = FileManager.default.fileExists(atPath: to)
        if !fromExists && toExists { return nil }
        guard fromExists else { return "Couldn't undo because \(from) is missing." }
        guard !toExists else { return "Couldn't undo because \(to) already exists." }
        let parent = (to as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent) else {
            return "Couldn't undo because \(parent) is missing."
        }
        do {
            try FileManager.default.moveItem(atPath: from, toPath: to)
            return nil
        } catch {
            return "Couldn't undo: \(error.localizedDescription)"
        }
    }

    private static func trashCopy(_ raw: String) -> String? {
        guard let path = homePath(raw) else { return "Refused to undo \(raw)." }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
            return nil
        } catch {
            return "Couldn't undo the copy: \(error.localizedDescription)"
        }
    }

    private static func removeEmptyFolder(_ raw: String) -> String? {
        guard let path = homePath(raw) else { return "Refused to remove \(raw)." }
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        guard isDir.boolValue else { return "\(path) is a file, so it was left in place." }
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path), children.isEmpty else {
            return "Left \(path) in place because it is not empty."
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            return nil
        } catch {
            return "Couldn't remove \(path)."
        }
    }

    private static func homePath(_ raw: String) -> String? {
        guard case .success(let path) = PathGuard.accept(raw) else { return nil }
        return path
    }

    /// A trashed file sits in ~/.Trash, which PathGuard refuses. Only that folder may be a move source.
    private static func sourcePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if PathGuard.isUserTrashItem(trimmed) {
            return (trimmed as NSString).expandingTildeInPath
        }
        return homePath(trimmed)
    }

    private static func fileURL() -> URL {
        let home = NSHomeDirectory() as NSString
        let library = home.appendingPathComponent("Library")
        let support = (library as NSString).appendingPathComponent("Application Support")
        let folder = (support as NSString).appendingPathComponent("Model Picker")
        return URL(fileURLWithPath: (folder as NSString).appendingPathComponent("undo.json"))
    }

    private static func load() -> [UndoEntry] {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? JSONDecoder().decode(UndoFile.self, from: data) else { return [] }
        return file.entries
    }

    private static func save(_ entries: [UndoEntry]) -> Bool {
        let url = fileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(UndoFile(entries: entries))
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

private struct UndoFile: Codable {
    var entries: [UndoEntry]
}
