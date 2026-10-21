import Foundation

/// Builds a PendingAction from tool arguments. Reads the disk to spot collisions. Writes nothing.
@MainActor
extension ActionCenter {
    static func planMove(paths: [String], destinationFolder: String) -> PendingAction {
        planTransfer(kind: .move, paths: paths, destinationFolder: destinationFolder, copying: false)
    }

    static func planCopy(paths: [String], destinationFolder: String) -> PendingAction {
        planTransfer(kind: .copy, paths: paths, destinationFolder: destinationFolder, copying: true)
    }

    static func planRename(path: String, newName: String) -> PendingAction {
        guard let name = cleanName(newName) else {
            return .failed(kind: .rename, summary: "Use a single file name, without a folder path.")
        }
        switch FileTools2.resolve(path) {
        case .failure(let reason):
            return .failed(kind: .rename, summary: FileTools2.refusal(reason))
        case .success(let source):
            guard FileManager.default.fileExists(atPath: source) else {
                return .failed(kind: .rename, summary: "No file at \(source).")
            }
            let parent = (source as NSString).deletingLastPathComponent
            let current = (source as NSString).lastPathComponent
            if current.caseInsensitiveCompare(name) == .orderedSame {
                return .failed(kind: .rename, summary: "\(current) already has that name.")
            }
            var reserved = Set<String>()
            let claimed = claim(folder: parent, desired: name, ignoring: source, reserved: &reserved)
            var warnings: [String] = []
            if let warning = claimed.warning { warnings.append(warning) }
            return PendingAction(
                id: UUID(),
                kind: .rename,
                title: "Rename \(current)",
                summary: "Rename \(current) to \((claimed.path as NSString).lastPathComponent). Nothing changes until you approve.",
                transfers: [PendingAction.Transfer(source: source, destination: claimed.path)],
                warnings: warnings,
                phase: .pending,
                resultText: nil,
                undoID: nil,
                ensureFolder: nil
            )
        }
    }

    static func planCreateFolder(path raw: String) -> PendingAction {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failed(kind: .createFolder, summary: "Say which folder to create.")
        }
        switch FileTools2.resolve(trimmed) {
        case .failure(let reason):
            return .failed(kind: .createFolder, summary: FileTools2.refusal(reason))
        case .success(let path):
            if PathGuard.isHome(path) {
                return .failed(kind: .createFolder, summary: "That folder already exists.")
            }
            var isDir = ObjCBool(false)
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return .failed(kind: .createFolder, summary: "\(path) already exists.")
                }
                return .failed(kind: .createFolder, summary: "\(path) is a file, not a folder.")
            }
            let name = (path as NSString).lastPathComponent
            return PendingAction(
                id: UUID(),
                kind: .createFolder,
                title: "Create folder",
                summary: "Create a folder named \(name). Nothing changes until you approve.",
                transfers: [PendingAction.Transfer(source: "New folder", destination: path)],
                warnings: [],
                phase: .pending,
                resultText: nil,
                undoID: nil,
                ensureFolder: path
            )
        }
    }

    static func planTrash(paths: [String]) -> PendingAction {
        if paths.isEmpty {
            return .failed(kind: .trash, summary: "Say which files to move to the Trash.")
        }
        var warnings: [String] = []
        var transfers: [PendingAction.Transfer] = []
        for raw in paths {
            switch FileTools2.resolve(raw) {
            case .failure(let reason):
                warnings.append(FileTools2.refusal(reason))
            case .success(let source):
                if PathGuard.isHome(source) {
                    warnings.append("Refusing to trash the home folder.")
                    continue
                }
                guard FileManager.default.fileExists(atPath: source) else {
                    warnings.append("No file at \(source).")
                    continue
                }
                transfers.append(PendingAction.Transfer(source: source, destination: "Trash"))
            }
        }
        if transfers.isEmpty {
            let detail = warnings.isEmpty ? "Nothing to move to the Trash." : warnings.joined(separator: " ")
            return .failed(kind: .trash, summary: detail)
        }
        let count = transfers.count
        let noun = count == 1 ? "item" : "items"
        return PendingAction(
            id: UUID(),
            kind: .trash,
            title: "Move \(count) \(noun) to the Trash",
            summary: "Move \(count) \(noun) to the Trash. Nothing is permanently deleted, and nothing changes until you approve.",
            transfers: transfers,
            warnings: warnings,
            phase: .pending,
            resultText: nil,
            undoID: nil,
            ensureFolder: nil
        )
    }

    private static func planTransfer(
        kind: PendingAction.Kind,
        paths: [String],
        destinationFolder: String,
        copying: Bool
    ) -> PendingAction {
        let verb = copying ? "Copy" : "Move"
        if paths.isEmpty {
            return .failed(kind: kind, summary: "Say which files to \(verb.lowercased()).")
        }
        let rawDest = destinationFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawDest.isEmpty {
            return .failed(kind: kind, summary: "Say which folder to \(verb.lowercased()) them into.")
        }
        let destRoot: String
        switch FileTools2.resolve(rawDest) {
        case .failure(let reason):
            return .failed(kind: kind, summary: FileTools2.refusal(reason))
        case .success(let path):
            destRoot = path
        }
        var isDir = ObjCBool(false)
        if FileManager.default.fileExists(atPath: destRoot, isDirectory: &isDir), !isDir.boolValue {
            return .failed(kind: kind, summary: "\(destRoot) is a file, not a folder.")
        }
        var warnings: [String] = []
        if !FileManager.default.fileExists(atPath: destRoot) {
            warnings.append("Will create folder \(destRoot).")
        }
        var reserved = Set<String>()
        var transfers: [PendingAction.Transfer] = []
        for raw in paths {
            switch FileTools2.resolve(raw) {
            case .failure(let reason):
                warnings.append(FileTools2.refusal(reason))
            case .success(let source):
                guard FileManager.default.fileExists(atPath: source) else {
                    warnings.append("No file at \(source).")
                    continue
                }
                if isInside(destRoot, source) {
                    warnings.append("Skipped \(source): the destination is inside it.")
                    continue
                }
                let name = (source as NSString).lastPathComponent
                let claimed = claim(
                    folder: destRoot,
                    desired: name,
                    ignoring: copying ? nil : source,
                    reserved: &reserved
                )
                if !copying && samePath(claimed.path, source) {
                    warnings.append("\(name) is already in that folder.")
                    continue
                }
                if let warning = claimed.warning { warnings.append(warning) }
                transfers.append(PendingAction.Transfer(source: source, destination: claimed.path))
            }
        }
        if transfers.isEmpty {
            let detail = warnings.isEmpty ? "Nothing to \(verb.lowercased())." : warnings.joined(separator: " ")
            return .failed(kind: kind, summary: detail)
        }
        let count = transfers.count
        let noun = count == 1 ? "item" : "items"
        let folderName = (destRoot as NSString).lastPathComponent
        return PendingAction(
            id: UUID(),
            kind: kind,
            title: "\(verb) \(count) \(noun)",
            summary: "\(verb) \(count) \(noun) into \(folderName). Nothing changes until you approve.",
            transfers: transfers,
            warnings: warnings,
            phase: .pending,
            resultText: nil,
            undoID: nil,
            ensureFolder: destRoot
        )
    }

    private static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { return nil }
        if name.contains("/") || name.contains("\0") || name.contains("\n") || name.contains("\r") {
            return nil
        }
        if name.hasPrefix(".") { return nil }
        return name
    }

    /// Creates missing parents of an allowed home path. Returns only folders this call made.
    static func makeFolder(_ path: String) -> (created: [String], error: String?) {
        guard case .success(let root) = PathGuard.accept(path) else {
            return ([], "That folder isn't allowed.")
        }
        var isDir = ObjCBool(false)
        if FileManager.default.fileExists(atPath: root, isDirectory: &isDir) {
            if isDir.boolValue { return ([], nil) }
            return ([], "\(root) is a file, not a folder.")
        }
        var current = ""
        var created: [String] = []
        for part in root.split(separator: "/").map(String.init) {
            current += "/" + part
            var existing = ObjCBool(false)
            if FileManager.default.fileExists(atPath: current, isDirectory: &existing) {
                if !existing.boolValue {
                    return (created, "\(current) is a file, not a folder.")
                }
                continue
            }
            guard case .success = PathGuard.accept(current) else {
                return (created, "That folder isn't allowed.")
            }
            do {
                try FileManager.default.createDirectory(atPath: current, withIntermediateDirectories: false)
                created.append(current)
            } catch {
                return (created, "Couldn't create \(current).")
            }
        }
        return (created, nil)
    }

    static func claim(
        folder: String,
        desired: String,
        ignoring: String?,
        reserved: inout Set<String>
    ) -> (path: String, warning: String?) {
        let ext = (desired as NSString).pathExtension
        let base = (desired as NSString).deletingPathExtension
        var number = 1
        while number < 500 {
            let name = number == 1 ? desired : numbered(base, ext, number)
            let path = (folder as NSString).appendingPathComponent(name)
            let key = path.lowercased()
            let isSelf = ignoring.map { samePath(path, $0) } ?? false
            let taken = reserved.contains(key) || (!isSelf && FileManager.default.fileExists(atPath: path))
            if !taken {
                reserved.insert(key)
                let warning = number == 1 ? nil : "\(desired) already exists there. It will be named \(name)."
                return (path, warning)
            }
            number = number == 1 ? 2 : number + 1
        }
        let fallback = (folder as NSString).appendingPathComponent(desired)
        return (fallback, "Couldn't find a free name for \(desired).")
    }

    private static func numbered(_ base: String, _ ext: String, _ number: Int) -> String {
        ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// True when `path` is `folder` or a descendant of it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        if samePath(path, folder) { return true }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
    }
}
