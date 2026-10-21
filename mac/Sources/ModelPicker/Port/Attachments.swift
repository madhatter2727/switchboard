import AppKit
import Foundation
import UniformTypeIdentifiers

/// Files and pictures added to a chat (paste, drag and drop, or the paperclip). Copies of pasted or dropped
/// data live in ~/Library/Application Support/Model Picker/attachments. Documents are read in full.
enum Attachments {
    static let dir = SUPPORT + "/attachments"
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]
    static func isImage(_ p: String) -> Bool { imageExts.contains((p as NSString).pathExtension.lowercased()) }

    /// A JPEG/PNG data URL a vision model can take (HEIC/TIFF are converted; very large photos are scaled to 2048 px on the long side).
    static func dataURL(_ path: String) -> String? {
        guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), s = min(1, 2048 / max(w, h))
        let nw = Int(w * s), nh = Int(h * s)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
        ctx.interpolationQuality = .high; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return "data:image/jpeg;base64," + jpg.base64EncodedString()
    }

    /// A JPEG copy (max 2048 px) for sending to Photo Reader, which can't read HEIC; the original is never changed.
    static func sendCopy(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard ["heic", "heif", "tiff", "tif", "bmp", "webp"].contains(ext) || size > 3_000_000,
              let u = dataURL(path), let d = Data(base64Encoded: String(u.dropFirst("data:image/jpeg;base64,".count))) else { return path }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let out = dir + "/send-copy-" + String(UUID().uuidString.prefix(8)) + ".jpg"
        return (try? d.write(to: URL(fileURLWithPath: out))) != nil ? out : path
    }

    /// Everything the chat needs about one file.
    static func info(_ path: String, real: Bool) -> [String: Any] {
        let name = (path as NSString).lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        var r: [String: Any] = ["ok": true, "path": path, "name": name, "bytes": size, "real": real]
        if isImage(path) {
            r["kind"] = "image"
            if let u = dataURL(path) { r["dataURL"] = u } else { r["ok"] = false; r["err"] = "That picture could not be opened." }
            return r
        }
        r["kind"] = "doc"
        let (ok, text) = mainSync { FileTools2.extractFullText(path: path) }
        if ok { r["text"] = text; r["chars"] = text.count } else { r["ok"] = false; r["err"] = text }
        return r
    }

    /// Pasted or dropped data (base64) saved as a file, then read.
    static func save(name raw: String, b64: String) -> [String: Any] {
        guard let data = Data(base64Encoded: b64) else { return ["ok": false, "err": "The file data was damaged."] }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var name = (raw as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
        if name.isEmpty { name = "pasted.png" }
        let p = dir + "/" + String(UUID().uuidString.prefix(8)) + "-" + name
        do { try data.write(to: URL(fileURLWithPath: p)) } catch { return ["ok": false, "err": error.localizedDescription] }
        var r = info(p, real: false); r["name"] = name; return r
    }

    @MainActor static func pick() -> [String] {
        let pan = NSOpenPanel(); pan.allowsMultipleSelection = true; pan.canChooseDirectories = false
        pan.message = "Add files or pictures to the chat"
        NSApp.activate(ignoringOtherApps: true)
        return pan.runModal() == .OK ? pan.urls.map(\.path) : []
    }
}
