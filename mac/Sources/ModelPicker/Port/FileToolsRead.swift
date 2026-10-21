import AppKit
import Foundation
import PDFKit

extension FileTools2 {
    private static var textLimit: Int { 4000 }

    /// PDF via PDFKit (first 4000 characters). RTF and docx via NSAttributedString. Else plain text.
    static func readFileText(path raw: String) -> String {
        switch resolve(raw) {
        case .failure(let reason):
            return refusal(reason)
        case .success(let path):
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return "No file at \(path)."
            }
            let ext = (path as NSString).pathExtension.lowercased()
            if isDirectory.boolValue && ext != "rtfd" {
                return "\(path) is a folder. Use list_folder."
            }
            let body = readBody(path: path, ext: ext)
            if body.isEmpty { return "\(path) has no text I can read." }
            return "\(path)\n\(body)"
        }
    }

    /// Path, app name, or URL. Opening does not change files.
    static func openItem(_ target: String) async -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Missing target." }

        if let remote = remoteURL(trimmed) {
            let opened = NSWorkspace.shared.open(remote)
            return opened ? "Opened \(trimmed)." : "Couldn't open \(trimmed)."
        }

        if looksLikePath(trimmed) || homeFileExists(trimmed) {
            switch resolve(trimmed) {
            case .failure(let reason):
                return refusal(reason)
            case .success(let path):
                guard FileManager.default.fileExists(atPath: path) else {
                    return "No file at \(path)."
                }
                let opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
                return opened ? "Opened \(path)." : "Couldn't open \(path)."
            }
        }

        guard let appURL = applicationURL(named: trimmed) else {
            return "No application named \(trimmed)."
        }
        return await openApplication(at: appURL)
    }

    private static func readBody(path: String, ext: String) -> String {
        let url = URL(fileURLWithPath: path)
        switch ext {
        case "pdf":
            return readPDF(url)
        case "rtf":
            return readAttributed(url, type: .rtf)
        case "rtfd":
            return readAttributed(url, type: .rtfd)
        case "docx":
            return readAttributed(url, type: .officeOpenXML)
        case "doc":
            return readAttributed(url, type: .docFormat)
        default:
            return readPlain(url)
        }
    }

    private static func readPDF(_ url: URL) -> String {
        guard let document = PDFDocument(url: url) else {
            return "Couldn't open that PDF."
        }
        var text = document.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var parts: [String] = []
            let pageStop = min(document.pageCount, 30)
            for index in 0 ..< pageStop {
                if let pageText = document.page(at: index)?.string {
                    parts.append(pageText)
                }
                if parts.joined().count >= textLimit { break }
            }
            text = parts.joined(separator: "\n")
        }
        return clip(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func readAttributed(_ url: URL, type: NSAttributedString.DocumentType?) -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any]
        if let type {
            options = [.documentType: type]
        } else {
            options = [:]
        }
        guard let text = try? NSAttributedString(url: url, options: options, documentAttributes: nil).string else {
            return "Couldn't read that document."
        }
        return clip(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func readPlain(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "Couldn't read that file."
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64 * 1024)
        if data.isEmpty { return "" }
        if let text = decodeUTF8(data) {
            return clip(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if data.contains(0) { return "This file isn't plain text." }
        guard let text = String(data: data, encoding: .isoLatin1) else {
            return "Couldn't read that file as text."
        }
        return clip(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Drop a split code unit at the end of a byte prefix, then decode UTF-8.
    private static func decodeUTF8(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        var trimmed = data
        for _ in 0 ..< 3 {
            guard !trimmed.isEmpty else { return nil }
            trimmed.removeLast()
            if let text = String(data: trimmed, encoding: .utf8) { return text }
        }
        return nil
    }

    private static func clip(_ text: String) -> String {
        guard text.count > textLimit else { return text }
        let end = text.index(text.startIndex, offsetBy: textLimit)
        return String(text[..<end]) + "\n[truncated to 4000 characters]"
    }

    private static func remoteURL(_ text: String) -> URL? {
        guard text.contains("://"), let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        if scheme == "file" { return nil }
        return url
    }

    private static func looksLikePath(_ text: String) -> Bool {
        text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("file:") || text.contains("/")
    }

    private static func homeFileExists(_ text: String) -> Bool {
        guard !looksLikePath(text) else { return false }
        let underHome = (NSHomeDirectory() as NSString).appendingPathComponent(text)
        guard case .success(let path) = PathGuard.accept(underHome) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private static func applicationURL(named name: String) -> URL? {
        let fileName = name.lowercased().hasSuffix(".app") ? name : name + ".app"
        var roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications/Utilities"
        ]
        roots.append((NSHomeDirectory() as NSString).appendingPathComponent("Applications"))
        let manager = FileManager.default
        for root in roots {
            guard let names = try? manager.contentsOfDirectory(atPath: root) else { continue }
            if let match = names.first(where: { $0.compare(fileName, options: .caseInsensitive) == .orderedSame }) {
                return URL(fileURLWithPath: (root as NSString).appendingPathComponent(match))
            }
        }
        if name.contains("."), !name.contains(" "),
           let url = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: name).first {
            return url
        }
        return nil
    }

    private static func openApplication(at url: URL) async -> String {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            let running = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            let name = running.localizedName ?? url.deletingPathExtension().lastPathComponent
            return "Opened \(name)."
        } catch {
            let name = url.deletingPathExtension().lastPathComponent
            return "Couldn't open \(name): \(error.localizedDescription)"
        }
    }
}
