import AppKit
import Foundation

/// Web pages and games the models make. They are saved as real .html files and opened in the web browser,
/// never run inside the app (so a broken or endless game can't freeze Model Picker).
@MainActor
enum Creations {
    nonisolated static let dir = NSHomeDirectory() + "/Documents/Model Picker Creations"
    nonisolated static func isWeb(_ p: String) -> Bool { ["html", "htm"].contains((p as NSString).pathExtension.lowercased()) }

    /// The user's default web browser (whatever opens https links), or nil.
    static func browser() -> URL? { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) }
    static func browserName() -> String { browser().map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "your browser" }

    /// Opens a web file in the browser (not in an editor), so the page actually runs.
    static func openInBrowser(_ path: String) -> Bool {
        let u = URL(fileURLWithPath: path)
        guard let b = browser() else { return NSWorkspace.shared.open(u) }
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        NSWorkspace.shared.open([u], withApplicationAt: b, configuration: cfg, completionHandler: nil)
        return true
    }

    /// Same path rules as create_file: a plain name means the Desktop; home folder only.
    static func resolve(_ raw: String) -> String? {
        var t = FileWrite.fixHome(raw)
        if t.isEmpty { return nil }
        if !t.contains("/") && !t.hasPrefix("~") { t = "Desktop/" + t }
        if case .success(let p) = FileTools2.resolve(t), FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    /// Save code from a chat answer as a new .html file in ~/Documents/Model Picker Creations (never overwrites).
    static func save(name: String, html: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var base = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.count > 40 { base = String(base.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        if base.isEmpty { base = "creation" }
        var p = dir + "/" + base + ".html"; var n = 2
        while fm.fileExists(atPath: p) { p = dir + "/" + base + "-\(n).html"; n += 1 }
        do { try html.data(using: .utf8)!.write(to: URL(fileURLWithPath: p), options: .withoutOverwriting) } catch { return nil }
        return p
    }
}
