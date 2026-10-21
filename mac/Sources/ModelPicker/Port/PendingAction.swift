import Foundation

/// A file change waiting for approval. Planning never touches the disk.
struct PendingAction: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case move
        case rename
        case copy
        case createFolder
        case trash
        case calendarEvent
    }

    enum Phase: Equatable {
        case pending
        case done
        case cancelled
        case failed
        case undone
    }

    struct Transfer: Identifiable, Equatable {
        var id: UUID
        var source: String
        var destination: String

        init(id: UUID = UUID(), source: String, destination: String) {
            self.id = id
            self.source = source
            self.destination = destination
        }
    }

    var id: UUID
    var kind: Kind
    var title: String
    var summary: String
    var transfers: [Transfer]
    var warnings: [String]
    var phase: Phase
    var resultText: String?
    var undoID: UUID?
    /// Destination directory for a move or copy. Nil for rename, trash, and create.
    var ensureFolder: String?
    /// Set for a new calendar event. File actions leave these empty.
    var eventTitle: String? = nil
    var eventStart: Date? = nil
    var eventEnd: Date? = nil
    var eventAllDay: Bool = false

    var previewText: String {
        var lines = [title, summary]
        for transfer in transfers {
            lines.append("\(transfer.source) → \(transfer.destination)")
        }
        lines.append(contentsOf: warnings)
        return lines.joined(separator: "\n")
    }

    static func failed(kind: Kind, summary: String) -> PendingAction {
        PendingAction(
            id: UUID(),
            kind: kind,
            title: "Can't do that",
            summary: summary,
            transfers: [],
            warnings: [],
            phase: .failed,
            resultText: nil,
            undoID: nil,
            ensureFolder: nil
        )
    }
}
