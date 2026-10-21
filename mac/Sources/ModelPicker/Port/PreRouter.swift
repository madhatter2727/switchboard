import Foundation

/// Obvious file commands run here, before the model, so they still work
/// when Osaurus is offline or the small model skips the tool call.
enum PreRouter {
    enum Route: Equatable {
        case searchFiles(String)
        case openDocument(String)
        case moveLastWeekScreenshots
        case calendar(CalendarSpan)
    }

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "pages", "txt", "md", "rtf", "rtfd",
        "key", "numbers", "xlsx", "xls", "ppt", "pptx", "csv"
    ]

    /// Bundles Spotlight reports as directories. They are still documents.
    private static let packageExtensions: Set<String> = [
        "pages", "key", "numbers", "rtfd"
    ]

    static func match(_ raw: String) -> Route? {
        // "Open the PDF about…" is an unfinished suggestion, not a command.
        if raw.contains("…") || raw.hasSuffix("...") { return nil }
        var text = collapse(raw)
        text = stripWrappingQuotes(text)
        text = stripLeadIn(text)
        guard !text.isEmpty else { return nil }

        let searchPrefixes = ["find my ", "where is my ", "where's my ", "where’s my "]
        for prefix in searchPrefixes {
            if let query = nonempty(polish(capture(text, prefix: prefix))) {
                return .searchFiles(query)
            }
        }
        if let query = nonempty(polish(capture(text, prefix: "open "))) {
            if contextQueries.contains(query.lowercased()) { return nil }
            return .openDocument(query)
        }
        if isLastWeekScreenshotArchive(text) {
            return .moveLastWeekScreenshots
        }
        if let span = CalendarTools.span(in: text) {
            return .calendar(span)
        }
        return nil
    }

    /// These only make sense after an earlier result. Let the model use that context.
    private static let contextQueries: Set<String> = [
        "it", "that", "this", "them", "one",
        "that one", "this one", "the one", "the file", "that file", "this file",
        "the first", "the second", "the third", "the last",
        "the first one", "the second one", "the third one", "the last one"
    ]

    /// Runs the shortcut and returns the assistant message. Does not call the model.
    static func perform(_ route: Route) async -> ChatMessage {
        switch route {
        case .searchFiles(let query):
            let paths = FileTools.searchFiles(query: query)
            return ChatMessage(
                role: .assistant,
                text: foundText(query: query, count: paths.count),
                toolNames: ["search_files"],
                filePaths: paths
            )
        case .openDocument(let query):
            let paths = FileTools.searchFiles(query: query)
            var names = ["search_files"]
            let summary: String
            if let doc = topDocument(in: paths) {
                names.append("open_item")
                summary = await FileTools2.openItem(doc)
            } else if paths.isEmpty {
                summary = foundText(query: query, count: 0)
            } else {
                summary = "I found items matching “\(query)”, but no document to open."
            }
            return ChatMessage(
                role: .assistant,
                text: summary,
                toolNames: names,
                filePaths: paths
            )
        case .moveLastWeekScreenshots:
            return await moveLastWeekScreenshots()
        case .calendar(let span):
            return ChatMessage(
                role: .assistant,
                text: await CalendarTools.report(span),
                toolNames: ["calendar_events"]
            )
        }
    }

    /// Suggestion chip: list last week's screenshots, then a pending move into ~/Desktop/Archive.
    private static func moveLastWeekScreenshots() async -> ChatMessage {
        let listing = await FileTools2.listFilesByDate(folder: nil, daysBack: 7, nameContains: "Screenshot")
        let paths = listedPaths(listing)
        if paths.isEmpty {
            let text = listing.contains("No files matched.")
                ? "I didn't find any screenshots from the last week."
                : listing
            return ChatMessage(role: .assistant, text: text, toolNames: ["list_files_by_date"])
        }
        let desktop = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        let archive = (desktop as NSString).appendingPathComponent("Archive")
        var action = await ActionCenter.planMove(paths: paths, destinationFolder: archive)
        guard action.phase == .pending else {
            return ChatMessage(
                role: .assistant,
                text: action.summary,
                toolNames: ["list_files_by_date", "move_items"]
            )
        }
        let count = action.transfers.count
        action.title = "Move \(count) " + (count == 1 ? "screenshot" : "screenshots")
        action.summary = "Move last week's screenshots into Archive on the Desktop. Nothing changes until you approve."
        return ChatMessage(
            role: .assistant,
            text: "",
            toolNames: ["list_files_by_date", "move_items"],
            pending: action
        )
    }

    private static func listedPaths(_ listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("/") else { return nil }
            return text
        }
    }

    private static func isLastWeekScreenshotArchive(_ text: String) -> Bool {
        let lower = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        guard lower.hasPrefix("move ") else { return false }
        guard lower.contains("screenshot") else { return false }
        guard lower.contains("last week") || lower.contains("past week") else { return false }
        guard let range = lower.range(of: " to ") ?? lower.range(of: " into ") else { return false }
        let dest = String(lower[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        return archiveDestinations.contains(dest)
    }

    private static let archiveDestinations: Set<String> = [
        "archive",
        "an archive",
        "the archive",
        "my archive",
        "archive folder",
        "an archive folder",
        "the archive folder",
        "my archive folder",
        "archive on the desktop",
        "archive on my desktop",
        "an archive folder on the desktop",
        "an archive folder on my desktop",
        "the archive folder on the desktop",
        "the archive folder on my desktop"
    ]

    /// First real document in the order search_files already ranked.
    static func topDocument(in paths: [String]) -> String? {
        for path in paths {
            let ext = (path as NSString).pathExtension.lowercased()
            guard documentExtensions.contains(ext) else { continue }
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue && !packageExtensions.contains(ext) { continue }
            return path
        }
        return nil
    }

    private static func foundText(query: String, count: Int) -> String {
        switch count {
        case 0:
            return "I couldn't find anything matching “\(query)”."
        case 1:
            return "Found 1 item."
        default:
            return "Found \(count) items."
        }
    }

    private static func capture(_ text: String, prefix: String) -> String? {
        guard let range = text.range(of: prefix, options: [.caseInsensitive, .anchored]) else {
            return nil
        }
        return String(text[range.upperBound...])
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.isEmpty ? nil : text
    }

    private static func polish(_ query: String?) -> String? {
        guard var text = query else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = CharacterSet(charactersIn: "\"'“”‘’.,!?;:…")
        let quotes = CharacterSet(charactersIn: "\"'“”‘’")
        while let scalar = text.unicodeScalars.last, trailing.contains(scalar) {
            text.unicodeScalars.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let scalar = text.unicodeScalars.first, quotes.contains(scalar) {
            text.unicodeScalars.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: " please", options: [.caseInsensitive, .backwards, .anchored]) {
            text = String(text[..<range.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLeadIn(_ text: String) -> String {
        var text = text
        let prefixes = ["please ", "can you ", "could you ", "would you "]
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for prefix in prefixes {
                guard let range = text.range(of: prefix, options: [.caseInsensitive, .anchored]) else { continue }
                text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                keepGoing = true
            }
        }
        return text
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last else { return text }
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
        for (open, close) in pairs where first == open && last == close {
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func collapse(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).map(String.init).joined(separator: " ")
    }
}
