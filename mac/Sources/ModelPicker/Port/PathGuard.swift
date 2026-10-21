import Darwin
import Foundation

/// Resolves symlinks, then allows a path only when it sits inside the
/// user's home directory. Refuses ~/Library, hidden dot-directories,
/// and system locations.
enum PathGuard {
    enum Refusal: Error, Equatable {
        case outsideHome
        case library
        case hidden
        case system
    }

    /// Symlink-resolved path that file tools may touch.
    static func accept(_ rawPath: String) -> Result<String, Refusal> {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("\0") || trimmed.contains("\n") || trimmed.contains("\r") {
            return .failure(.outsideHome)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard let resolved = canonicalize(expanded) else {
            return .failure(.outsideHome)
        }
        guard isInsideHome(resolved) else {
            return .failure(isSystem(resolved) ? .system : .outsideHome)
        }
        if isUserLibrary(resolved) {
            return .failure(.library)
        }
        if hasHiddenComponent(resolved) {
            return .failure(.hidden)
        }
        return .success(resolved)
    }

    /// Follow symlinks and `..` in the same walk. `standardizingPath` would
    /// erase `..` before the link target is known, so a link could escape home.
    private static func canonicalize(_ path: String) -> String? {
        let absolute = absolutePath(path)
        if !hasDotSegment(absolute), let existing = existingCanonical(absolute) {
            return existing
        }
        guard let walked = walk(absolute) else { return nil }
        return existingCanonical(walked) ?? walked
    }

    private static func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
    }

    private static func hasDotSegment(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    /// Flatten each existing prefix with `realpath` before applying a later
    /// `..`, so a symlink is not popped lexically.
    private static func walk(_ absolute: String) -> String? {
        var stack: [String] = []
        for partSub in absolute.split(separator: "/") {
            let part = String(partSub)
            if part == "." { continue }
            if part == ".." {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
                continue
            }
            stack.append(part)
            let current = join(stack)
            if let target = existingCanonical(current) {
                stack = target.split(separator: "/").map(String.init)
            } else if nodeExists(current) {
                // Present, but realpath could not see the target (loop or broken link).
                return nil
            }
        }
        return join(stack)
    }

    /// True for a real node or a symlink `fileExists` will not follow.
    private static func nodeExists(_ path: String) -> Bool {
        if FileManager.default.fileExists(atPath: path) { return true }
        return (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    private static func join(_ stack: [String]) -> String {
        stack.isEmpty ? "/" : "/" + stack.joined(separator: "/")
    }

    private static func existingCanonical(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return buffer.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress, realpath(path, base) != nil else { return nil }
            return String(cString: base)
        }
    }

    /// Home, plus its `/System/Volumes/Data` firmlink twin, so both forms compare equal.
    private static let homeRoots: [String] = makeHomeRoots()

    private static func makeHomeRoots() -> [String] {
        let raw = absolutePath(NSHomeDirectory())
        let canonical = canonicalize(raw) ?? raw
        let dataPrefix = "/System/Volumes/Data"
        var roots = [canonical, raw]
        for root in [canonical, raw] {
            if hasPrefix(root, "/Users/") {
                roots.append(dataPrefix + root)
            } else if hasPrefix(root, dataPrefix + "/Users/") {
                roots.append(String(root.dropFirst(dataPrefix.count)))
            }
        }
        var unique: [String] = []
        for root in roots where !root.isEmpty {
            let already = unique.contains { $0.caseInsensitiveCompare(root) == .orderedSame }
            if !already { unique.append(root) }
        }
        return unique
    }

    private static func hasPrefix(_ path: String, _ prefix: String) -> Bool {
        path.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
    }

    private static func isInsideHome(_ path: String) -> Bool {
        homeRoots.contains { isInside(path, home: $0) }
    }

    private static func isUserLibrary(_ path: String) -> Bool {
        homeRoots.contains { isLibrary(path, home: $0) }
    }

    private static func isInside(_ path: String, home: String) -> Bool {
        if path.caseInsensitiveCompare(home) == .orderedSame { return true }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return hasPrefix(path, prefix)
    }

    private static func isLibrary(_ path: String, home: String) -> Bool {
        let root = home.hasSuffix("/") ? String(home.dropLast()) : home
        let library = root + "/Library"
        if path.caseInsensitiveCompare(library) == .orderedSame { return true }
        return hasPrefix(path, library + "/")
    }

    private static func hasHiddenComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    private static let systemRoots = [
        "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
        "/private", "/dev", "/etc", "/var", "/tmp", "/opt", "/cores",
        "/Network", "/Volumes"
    ]

    private static func isSystem(_ path: String) -> Bool {
        for root in systemRoots {
            if path.caseInsensitiveCompare(root) == .orderedSame || hasPrefix(path, root + "/") {
                return true
            }
        }
        return false
    }

    /// True when the resolved path is the home folder itself.
    static func isHome(_ rawPath: String) -> Bool {
        guard case .success(let path) = accept(rawPath) else { return false }
        return homeRoots.contains { path.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// `~/.Trash` is hidden, so `accept` refuses it. Undo may still move a file back out.
    static func isUserTrashItem(_ rawPath: String) -> Bool {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("\0") { return false }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if trashChild(expanded) { return true }
        if let resolved = canonicalize(expanded), trashChild(resolved) { return true }
        return false
    }

    /// True when a `.Trash` component's parent is the home folder itself.
    private static func trashChild(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(where: { $0.caseInsensitiveCompare(".Trash") == .orderedSame }),
              index > 0
        else { return false }
        let parent = "/" + parts.prefix(index).joined(separator: "/")
        return homeRoots.contains { parent.caseInsensitiveCompare($0) == .orderedSame }
    }
}
