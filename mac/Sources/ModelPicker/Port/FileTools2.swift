import Foundation

/// Folder listing, file info, and files-by-date. Read and open are in FileToolsRead.swift.
/// AppKit calls stay on the main actor. Every path goes through PathGuard.
@MainActor
enum FileTools2 {
    private static let listLimit = 200

    static func listFolder(path raw: String) -> String {
        switch resolve(raw) {
        case .failure(let reason):
            return refusal(reason)
        case .success(let path):
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return "No folder at \(path)."
            }
            guard isDirectory.boolValue else {
                return "\(path) is a file. Use file_info or read_file_text."
            }
            return renderFolder(path)
        }
    }

    static func fileInfo(path raw: String) -> String {
        switch resolve(raw) {
        case .failure(let reason):
            return refusal(reason)
        case .success(let path):
            guard FileManager.default.fileExists(atPath: path) else {
                return "No file at \(path)."
            }
            return renderInfo(path)
        }
    }

    /// Files modified or created within `daysBack` days. Empty folder → screenshot location, else Desktop.
    static func listFilesByDate(folder: String?, daysBack: Int, nameContains: String?) -> String {
        let rawFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folderPath: String
        if rawFolder.isEmpty {
            folderPath = screenshotFolder()
        } else {
            switch resolve(rawFolder) {
            case .failure(let reason):
                return refusal(reason)
            case .success(let path):
                folderPath = path
            }
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "No folder at \(folderPath)."
        }

        let cutoff = cutoffDate(daysBack: daysBack)
        let needle = nameContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folderPath),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return "Couldn't list \(folderPath)."
        }

        var rows: [(date: Date, path: String)] = []
        for url in urls {
            guard case .success(let path) = PathGuard.accept(url.path) else { continue }
            var isDir = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard nameMatches(url.lastPathComponent, contains: needle) else { continue }
            guard let when = itemDate(path), when >= cutoff else { continue }
            rows.append((when, path))
        }
        rows.sort { $0.date > $1.date }

        var lines = ["Folder: \(folderPath)", "Since: \(iso(cutoff))"]
        if rows.isEmpty {
            lines.append("No files matched.")
            return lines.joined(separator: "\n")
        }
        lines.append(contentsOf: rows.prefix(listLimit).map { $0.path })
        if rows.count > listLimit {
            lines.append("[\(rows.count - listLimit) more not shown]")
        }
        return lines.joined(separator: "\n")
    }

    /// `defaults read com.apple.screencapture location`, else ~/Desktop.
    static func screenshotFolder() -> String {
        let desktop = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.screencapture", "location"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return desktop }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, var raw = String(data: data, encoding: .utf8) else {
            return desktop
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            raw = String(raw.dropFirst().dropLast())
        }
        guard !raw.isEmpty, case .success(let path) = PathGuard.accept(raw) else { return desktop }
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return desktop
        }
        return path
    }

    static func resolve(_ raw: String) -> Result<String, PathGuard.Refusal> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file:"), let url = URL(string: trimmed), url.isFileURL {
            return PathGuard.accept(url.path)
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return PathGuard.accept(trimmed)
        }
        let underHome = (NSHomeDirectory() as NSString).appendingPathComponent(trimmed)
        return PathGuard.accept(underHome)
    }

    static func refusal(_ reason: PathGuard.Refusal) -> String {
        switch reason {
        case .outsideHome:
            return "That path is outside the home folder."
        case .library:
            return "That path is in Library, which this app won't read."
        case .hidden:
            return "That path is inside a hidden folder."
        case .system:
            return "That path is a system location."
        }
    }

    private static func renderFolder(_ path: String) -> String {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return "Couldn't list \(path)."
        }

        struct Row {
            var name: String
            var folder: Bool
            var size: Int64
        }

        var rows: [Row] = []
        for url in urls {
            guard case .success(let child) = PathGuard.accept(url.path) else { continue }
            var isDir = ObjCBool(false)
            _ = FileManager.default.fileExists(atPath: child, isDirectory: &isDir)
            let size = fileSize(child)
            rows.append(Row(name: url.lastPathComponent, folder: isDir.boolValue, size: size))
        }
        rows.sort { lhs, rhs in
            if lhs.folder != rhs.folder { return lhs.folder }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        var lines = [path]
        if rows.isEmpty {
            lines.append("(empty)")
            return lines.joined(separator: "\n")
        }
        for row in rows.prefix(listLimit) {
            if row.folder {
                lines.append("folder\t\(row.name)")
            } else {
                lines.append("file\t\(row.size)\t\(row.name)")
            }
        }
        if rows.count > listLimit {
            lines.append("[\(rows.count - listLimit) more not shown]")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderInfo(_ path: String) -> String {
        var isDir = ObjCBool(false)
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let created = attrs[.creationDate] as? Date
        let modified = attrs[.modificationDate] as? Date
        let ext = (path as NSString).pathExtension
        var lines = [
            "path: \(path)",
            "name: \((path as NSString).lastPathComponent)",
            "kind: \(isDir.boolValue ? "folder" : "file")"
        ]
        if !ext.isEmpty { lines.append("extension: \(ext)") }
        if !isDir.boolValue { lines.append("size: \(fileSize(path)) bytes") }
        if let created { lines.append("created: \(iso(created))") }
        if let modified { lines.append("modified: \(iso(modified))") }
        return lines.joined(separator: "\n")
    }

    private static func fileSize(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.size] as? NSNumber
        else { return 0 }
        return number.int64Value
    }

    private static func cutoffDate(daysBack: Int) -> Date {
        if daysBack <= 0 {
            return Calendar.current.startOfDay(for: Date())
        }
        return Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
    }

    private static func itemDate(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let modified = attrs[.modificationDate] as? Date
        let created = attrs[.creationDate] as? Date
        return [modified, created].compactMap { $0 }.max()
    }

    /// "Screenshot" and "Screen Shot" are the two macOS capture prefixes.
    private static func nameMatches(_ name: String, contains needle: String?) -> Bool {
        guard let needle, !needle.isEmpty else { return true }
        let folded = needle.lowercased()
        if folded == "screenshot" || folded == "screenshots" || folded == "screen shot" || folded == "screen shots" {
            let lower = name.lowercased()
            if lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot") { return true }
        }
        return name.range(of: needle, options: .caseInsensitive) != nil
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
