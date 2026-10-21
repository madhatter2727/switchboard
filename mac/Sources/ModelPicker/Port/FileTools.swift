import Foundation

/// Read-only Spotlight search. Folder, info, read, date, and open live in FileTools2.
enum FileTools {
    private static let resultLimit = 15
    private static let documentExtensions: Set<String> = [
        "pdf", "docx", "pages", "txt", "md", "rtf", "key", "numbers", "xlsx"
    ]

    /// Spotlight name match plus a plain content query. At most 15 paths.
    /// Folders and documents rank ahead of code and other files.
    static func searchFiles(query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let home = NSHomeDirectory()
        var found: [String] = []
        if let predicate = namePredicate(trimmed) {
            found.append(contentsOf: runMdfind(onlyIn: home, query: predicate))
        }
        found.append(contentsOf: runMdfind(onlyIn: home, query: plainContentQuery(trimmed)))

        var seen = Set<String>()
        var ordered: [String] = []
        for raw in found {
            guard let path = allowed(raw) else { continue }
            if seen.insert(path.lowercased()).inserted {
                ordered.append(path)
            }
        }
        return Array(ranked(ordered).prefix(resultLimit))
    }

    /// `kMDItemFSName == '*q*'cd`. Quotes stay inside the predicate, not a shell.
    /// Nil when the query is only quote characters, so we don't match every file.
    private static func namePredicate(_ query: String) -> String? {
        let literal = spotlightLiteral(query)
        guard !literal.isEmpty else { return nil }
        return "kMDItemFSName == '*\(literal)*'cd"
    }

    /// The user's words as a content query. A leading "-" would be an mdfind
    /// option (`-live` never returns), so that case uses a text predicate.
    private static func plainContentQuery(_ query: String) -> String {
        guard query.hasPrefix("-") else { return query }
        let literal = spotlightLiteral(query)
        guard !literal.isEmpty else { return query }
        return "kMDItemTextContent == '*\(literal)*'cd"
    }

    private static func spotlightLiteral(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func allowed(_ raw: String) -> String? {
        guard case .success(let path) = PathGuard.accept(raw) else { return nil }
        if isExcluded(path) { return nil }
        return path
    }

    /// Drops dependency caches, source trees, Library, and hidden components.
    private static func isExcluded(_ path: String) -> Bool {
        let blocked = ["node_modules", ".git", "src", "Library"]
        for segment in blocked {
            if path.range(of: "/\(segment)/", options: .caseInsensitive) != nil {
                return true
            }
        }
        for part in path.split(separator: "/") {
            if part.hasPrefix(".") { return true }
            for segment in blocked where part.caseInsensitiveCompare(segment) == .orderedSame {
                return true
            }
        }
        return false
    }

    private static func ranked(_ paths: [String]) -> [String] {
        var preferred: [String] = []
        var rest: [String] = []
        for path in paths {
            if isFolderOrDocument(path) {
                preferred.append(path)
            } else {
                rest.append(path)
            }
        }
        return preferred + rest
    }

    private static func isFolderOrDocument(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
        let ext = (path as NSString).pathExtension.lowercased()
        return documentExtensions.contains(ext)
    }

    private static func runMdfind(onlyIn directory: String, query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", directory, trimmed]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.isEmpty }
    }
}
