import Foundation

/// Runs an approved PendingAction. Every path goes through PathGuard again.
/// Name collisions gain a " 2" suffix. Existing files are never overwritten.
@MainActor
enum ActionCenter {
    static func execute(_ action: PendingAction) -> PendingAction {
        guard action.phase == .pending else { return action }
        switch action.kind {
        case .move:
            return runTransfers(action, copying: false)
        case .copy:
            return runTransfers(action, copying: true)
        case .rename:
            return runTransfers(action, copying: false)
        case .createFolder:
            return runCreate(action)
        case .trash:
            return runTrash(action)
        case .calendarEvent:
            return saveCalendarEvent(action)
        }
    }

    private static func runTransfers(_ action: PendingAction, copying: Bool) -> PendingAction {
        let folder: String
        if let ensure = action.ensureFolder {
            switch FileTools2.resolve(ensure) {
            case .failure(let reason):
                return fail(action, FileTools2.refusal(reason))
            case .success(let path):
                folder = path
            }
        } else if let destination = action.transfers.first?.destination {
            let parent = (destination as NSString).deletingLastPathComponent
            switch FileTools2.resolve(parent) {
            case .failure(let reason):
                return fail(action, FileTools2.refusal(reason))
            case .success(let path):
                folder = path
            }
        } else {
            return fail(action, "Nothing to change.")
        }

        var isDir = ObjCBool(false)
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), !isDir.boolValue {
            return fail(action, "\(folder) is a file, not a folder.")
        }

        let made = makeFolder(folder)
        if let error = made.error {
            _ = UndoLog.perform(removalSteps(made.created))
            return fail(action, error)
        }

        var reserved = Set<String>()
        var steps: [UndoStep] = []
        var done: [PendingAction.Transfer] = []
        var lines: [String] = []
        for transfer in action.transfers {
            guard case .success(let source) = PathGuard.accept(transfer.source) else {
                lines.append("Skipped \(transfer.source): that path isn't allowed.")
                continue
            }
            guard FileManager.default.fileExists(atPath: source) else {
                lines.append("Skipped \(source): it is missing.")
                continue
            }
            if isInside(folder, source) {
                lines.append("Skipped \(source): the destination is inside it.")
                continue
            }
            let desired = (transfer.destination as NSString).lastPathComponent
            let claimed = claim(
                folder: folder,
                desired: desired,
                ignoring: copying ? nil : source,
                reserved: &reserved
            )
            if !copying && samePath(claimed.path, source) {
                lines.append("\(source) is already there.")
                continue
            }
            guard case .success(let destination) = PathGuard.accept(claimed.path) else {
                lines.append("Skipped \(claimed.path): that path isn't allowed.")
                continue
            }
            if FileManager.default.fileExists(atPath: destination) {
                lines.append("Skipped \(source): \(destination) already exists.")
                continue
            }
            if let warning = claimed.warning {
                lines.append(warning)
            }
            do {
                if copying {
                    try FileManager.default.copyItem(atPath: source, toPath: destination)
                    steps.append(UndoStep(op: "trash", from: nil, to: nil, path: destination))
                } else {
                    try FileManager.default.moveItem(atPath: source, toPath: destination)
                    steps.append(UndoStep(op: "move", from: destination, to: source, path: nil))
                }
                done.append(PendingAction.Transfer(source: source, destination: destination))
                lines.append("\(source) → \(destination)")
            } catch {
                lines.append("Couldn't change \(source): \(error.localizedDescription)")
            }
        }

        let verb = copying ? "Copied" : (action.kind == .rename ? "Renamed" : "Moved")
        if !done.isEmpty {
            lines.insert(countLine(verb, done.count), at: 0)
        }
        steps.append(contentsOf: removalSteps(made.created))
        return commit(action, steps: steps, transfers: done, lines: lines, created: made.created)
    }

    private static func runCreate(_ action: PendingAction) -> PendingAction {
        guard let raw = action.ensureFolder else { return fail(action, "Say which folder to create.") }
        switch FileTools2.resolve(raw) {
        case .failure(let reason):
            return fail(action, FileTools2.refusal(reason))
        case .success(let path):
            let made = makeFolder(path)
            if let error = made.error {
                _ = UndoLog.perform(removalSteps(made.created))
                return fail(action, error)
            }
            if made.created.isEmpty {
                return fail(action, "\(path) already exists.")
            }
            let steps = removalSteps(made.created)
            let lines = ["Created \(path)."]
            let transfers = [PendingAction.Transfer(source: "New folder", destination: path)]
            return commit(action, steps: steps, transfers: transfers, lines: lines, created: [])
        }
    }

    private static func runTrash(_ action: PendingAction) -> PendingAction {
        var steps: [UndoStep] = []
        var done: [PendingAction.Transfer] = []
        var lines: [String] = []
        for transfer in action.transfers {
            guard case .success(let source) = PathGuard.accept(transfer.source) else {
                lines.append("Skipped \(transfer.source): that path isn't allowed.")
                continue
            }
            if PathGuard.isHome(source) {
                lines.append("Refusing to trash the home folder.")
                continue
            }
            guard FileManager.default.fileExists(atPath: source) else {
                lines.append("Skipped \(source): it is missing.")
                continue
            }
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: source),
                    resultingItemURL: &resulting
                )
            } catch {
                lines.append("Couldn't move \(source) to the Trash: \(error.localizedDescription)")
                continue
            }
            guard let trashed = resulting?.path, !trashed.isEmpty else {
                lines.append("Moved \(source) to the Trash, but its new location is unknown.")
                done.append(PendingAction.Transfer(source: source, destination: "Trash"))
                continue
            }
            steps.append(UndoStep(op: "move", from: trashed, to: source, path: nil))
            done.append(PendingAction.Transfer(source: source, destination: trashed))
            lines.append("\(source) → \(trashed)")
        }
        if !steps.isEmpty {
            let noun = steps.count == 1 ? "item" : "items"
            lines.insert("Moved \(steps.count) \(noun) to the Trash.", at: 0)
        }
        return commit(action, steps: steps, transfers: done, lines: lines, created: [])
    }

    private static func commit(
        _ action: PendingAction,
        steps: [UndoStep],
        transfers: [PendingAction.Transfer],
        lines: [String],
        created: [String]
    ) -> PendingAction {
        var action = action
        let meaningful = steps.filter { $0.op != "removeEmptyFolder" }
        if meaningful.isEmpty && action.kind != .createFolder {
            _ = UndoLog.perform(removalSteps(created))
            action.phase = .failed
            action.resultText = lines.isEmpty ? "Nothing changed." : lines.joined(separator: "\n")
            return action
        }
        guard let id = UndoLog.record(kind: action.kind.rawValue, summary: action.title, steps: steps) else {
            let problem = UndoLog.perform(steps).error
            action.phase = .failed
            if let problem {
                action.resultText = "Couldn't save the undo log, and reversing the change failed: \(problem)"
            } else {
                action.resultText = "Couldn't save the undo log, so I reversed the change."
            }
            return action
        }
        action.phase = .done
        action.undoID = id
        action.transfers = transfers
        action.resultText = lines.joined(separator: "\n")
        return action
    }

    private static func fail(_ action: PendingAction, _ message: String) -> PendingAction {
        var action = action
        action.phase = .failed
        action.resultText = message
        return action
    }

    private static func removalSteps(_ folders: [String]) -> [UndoStep] {
        folders.reversed().map { UndoStep(op: "removeEmptyFolder", from: nil, to: nil, path: $0) }
    }

    private static func countLine(_ verb: String, _ count: Int) -> String {
        let noun = count == 1 ? "item" : "items"
        return "\(verb) \(count) \(noun)."
    }
}
